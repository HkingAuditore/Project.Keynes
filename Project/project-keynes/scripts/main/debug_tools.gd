extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func toggle_debug_console(host) -> void:
	if host._debug_console != null:
		host._debug_console.visible = not host._debug_console.visible


# 异步气候轮 A/B bench（GM 面板按钮 / B、V 热键）：kind = "transp" | "pass_a"。
# worker thread 跑 pure kernel，对比 sync 结果 bit-equal，报告打到 [async/bench] 前缀。

func run_async_climate_bench_debug(host, kind: String = "transp") -> void:
	if host._generator != null and host._generator.has_method("run_async_climate_round_bench"):
		host._generator.run_async_climate_round_bench(kind)
	elif kind == "transp" and host._generator != null and host._generator.has_method("run_async_climate_round_stage1_bench"):
		host._generator.run_async_climate_round_stage1_bench()
	else:
		push_warning("[async/bench] generator 缺 run_async_climate_round_bench()")


# 取 SusSchedulerExt（C++）引用。真实链路：MapGenerator._sus（DCSystemScheduler
# facade）→ ._sus（SusScheduler GDScript）→ ._ext（native，懒创建，未 tick 过
# 可能为 null）。任一层缺失返回 null。

func _sus_ext_ref(host):
	if host._generator == null or not ("_sus" in host._generator) or host._generator._sus == null:
		return null
	var facade = host._generator._sus
	if not ("_sus" in facade) or facade._sus == null:
		return null
	var sus = facade._sus
	if not ("_ext" in sus):
		return null
	return sus._ext


# 全局诊断日志（PKLog）开关（GM 面板按钮 / L 热键）。镜像到 C++ 端
# DCWorldExt / SusSchedulerExt，让原生 print 也响应。返回切换后的状态。

func toggle_diagnostic_logging_debug(host) -> void:
	PKLog.set_enabled(not PKLog.enabled,
		host._generator._data_core_world_ext if host._generator != null and "_data_core_world_ext" in host._generator else null,
		host._sus_ext_ref()
	)


func cycle_weather_debug_view(host) -> void:
	if host._renderer == null:
		print("[weather-debug] renderer null, cannot cycle weather debug view")
		return
	var weather_layer_node = host._renderer.get_node_or_null("WeatherLayer")
	if weather_layer_node == null:
		print("[weather-debug] WeatherLayer node not found")
		return
	if not weather_layer_node.has_method("set_weather_debug_view"):
		print("[weather-debug] WeatherLayer missing set_weather_debug_view")
		return
	var cur: int = int(weather_layer_node.call("get_weather_debug_view")) if weather_layer_node.has_method("get_weather_debug_view") else 0
	var count: int = int(weather_layer_node.call("get_weather_debug_view_count")) if weather_layer_node.has_method("get_weather_debug_view_count") else 8
	var next_view: int = (cur + 1) % maxi(count, 1)
	weather_layer_node.call("set_weather_debug_view", next_view)
	var name: String = str(weather_layer_node.call("get_weather_debug_view_name")) if weather_layer_node.has_method("get_weather_debug_view_name") else str(next_view)
	print("[weather-debug] view=%d (%s)" % [next_view, name])


# GM 面板 toggle 类 CheckBox 的状态回显源：给定 key 返回该开关当前的真值。
# 这些 toggle_* 方法都是"翻转内部 flag"语义，没有独立 getter，统一在此集中读回，
# 保证面板 CheckBox 的勾选态与运行时真值一致（热键/按钮任意路径改动都能同步）。

func get_debug_toggle_state(host, key: String) -> bool:
	match key:
		"perf_mini_hud":
			return host._perf_mini_hud != null and host._perf_mini_hud.visible
		"overlay_refresh_disabled":
			return host._overlay_refresh_disabled
		"atlas_upload_disabled":
			return host._render_profile_atlas_disabled
		"atlas_quarter_size":
			return host._render_profile_atlas_quarter_size
		"weather_hidden":
			return host._render_profile_weather_hidden
		"world_shader_disabled":
			return host._render_profile_world_shader_disabled
		"diagnostic_logging":
			return PKLog.enabled
		_:
			return false


# 2026-05-19：Mini Perf HUD 显隐切换。
# 默认 visible=true（一启动就能看到性能数据），F4 隐藏后内部 timer 也会停。

func toggle_perf_mini_hud(host) -> void:
	if host._perf_mini_hud != null and host._perf_mini_hud.has_method("toggle_visible"):
		host._perf_mini_hud.toggle_visible()


# ─── 60 FPS 调查热键（2026-06-14） ─────────────────────────────────────
# F3: dump Performance monitor 全量数据（GPU / draw calls / 内存 / 渲染时间）。
# 在移动端定位"主线程仿真已优化但仍 26 FPS"的真凶——是 GPU 端、Canvas 重建、
# 还是 atlas commit 拖慢了。


func toggle_overlay_refresh_disabled(host) -> void:
	host._overlay_refresh_disabled = not host._overlay_refresh_disabled
	print("[render-profile] overlay daily rebake disabled=%s (overlay frozen; A/B FPS to confirm fan-out cost)"
		% str(host._overlay_refresh_disabled))



func toggle_dynamic_visual_atlas_upload(host) -> void:
	host._render_profile_atlas_disabled = not host._render_profile_atlas_disabled
	# 通过 Engine.set_meta 全局通信，DVA 的 should_run 会读这个 flag。
	# 不调 unregister_job，保持 SUS topology 不变；下次 should_run 直接 return false。
	Engine.set_meta(&"force_disable_dva_upload", host._render_profile_atlas_disabled)
	print("[render-profile] dynamic_visual_atlas_upload disabled=%s (toggle to compare FPS)" % str(host._render_profile_atlas_disabled))


# F12: toggle atlas 强制 256 size（vs 默认 mobile 512）→ 重 bake 后 GPU 负载理论减半。

func toggle_atlas_resolution(host) -> void:
	host._render_profile_atlas_quarter_size = not host._render_profile_atlas_quarter_size
	# MapBaker._hm_max_dim 是 static 函数，不能直接 monkey-patch。最简单：
	# 用一个全局 flag，bake 时检测；或直接修 ProjectSettings 的某个值传递。
	# 这里用 Engine.set_meta 全局通信，MapBaker 入口检测：
	Engine.set_meta(&"force_atlas_quarter_size", host._render_profile_atlas_quarter_size)
	print("[render-profile] atlas_quarter_size=%s — triggering regenerate to rebake at %dpx" % [
		str(host._render_profile_atlas_quarter_size),
		256 if host._render_profile_atlas_quarter_size else 512,
	])
	host.regenerate_debug_map()


# F10 / mobile 按钮：toggle WeatherLayer visible（60 FPS 瓶颈调查，2026-06-14）。
# 完全隐藏 weather overlay → 整个 1046 行 fragment shader 不再为屏幕每个像素跑一次。
# 用 ΔFPS 反推 weather_overlay 占主线程多少 ms：
#   - FPS 40→55+：weather 是真凶（visual_quality 降级方向正确）
#   - FPS 40→45：weather 占 ~5ms，瓶颈分散
#   - FPS 40→40：weather 不是瓶颈，找其他 shader / SUS

func toggle_weather_layer_visible(host) -> void:
	if host._renderer == null:
		print("[render-profile] renderer null, cannot toggle WeatherLayer")
		return
	var weather_layer_node = host._renderer.get_node_or_null("WeatherLayer")
	if weather_layer_node == null:
		print("[render-profile] WeatherLayer node not found")
		return
	host._render_profile_weather_hidden = not host._render_profile_weather_hidden
	weather_layer_node.visible = not host._render_profile_weather_hidden
	print("[render-profile] WeatherLayer hidden=%s — 用 ΔFPS 判断 weather_overlay shader 占多少" % str(host._render_profile_weather_hidden))


# [terrain-material-tiles] GM 诊断：切换材质贴图门禁视图（terrain_surface_debug_view=7）。
# debug 分支绕过后处理直出纯色：绿=激活 / 蓝=tex 未绑定 / 品红=enabled=false / 橙=q<2。
# 同时把 GDScript 侧与材质侧的门禁值打到控制台，便于对照 shader 侧结果。

func toggle_terrain_material_gate_debug(host) -> void:
	if host._renderer == null:
		print("[terrain-mat-gate] renderer 不可用")
		return
	host._renderer.terrain_surface_debug_view = 0 \
		if host._renderer.terrain_surface_debug_view == 7 else 7
	print("[terrain-mat-gate] debug_view=%d（绿=激活 蓝=tex未绑定 品红=disabled 橙=q<2）" %
		host._renderer.terrain_surface_debug_view)
	print("[terrain-mat-gate] gd 侧: renderer.q=%d enabled=%s" % [
		host._renderer.visual_quality, str(host._renderer.terrain_materials_enabled)])
	var world = host._renderer._world
	if world != null:
		print("[terrain-mat-gate] world 侧: tex=%s bound=%s" % [
			str(world.terrain_material_tex != null),
			str(world.terrain_material_tex_bound)])
	var mat = host._renderer._shader_mat
	if mat != null:
		print("[terrain-mat-gate] 材质 uniform: enabled=%s bound=%s q=%s tex=%s" % [
			str(mat.get_shader_parameter("terrain_materials_enabled")),
			str(mat.get_shader_parameter("terrain_material_tex_bound")),
			str(mat.get_shader_parameter("visual_quality")),
			str(mat.get_shader_parameter("terrain_material_tex") != null)])


# 60 FPS 调查（2026-06-14）：toggle 主地形 shader（hex_terrain + world_map）。
# 把 _world_quad.material = null → fragment shader 不跑。如果 FPS 飙升说明
# 主地形 shader 是 GPU 瓶颈；如果不变则瓶颈在 Vulkan 驱动 / 其他全屏 quad。

func toggle_world_shader_disabled(host) -> void:
	if host._renderer == null:
		print("[render-profile] renderer null, cannot toggle world shader")
		return
	if not host._renderer.has_method("toggle_world_shader_disabled"):
		print("[render-profile] renderer missing toggle_world_shader_disabled method")
		return
	host._render_profile_world_shader_disabled = bool(host._renderer.toggle_world_shader_disabled())


# 60 FPS 调查（2026-06-14）：cycle visual_quality 0/1/2。
# 实测移动端 shader=OFF 时 frame=8ms，shader=ON 时 frame=28ms → 主地形 shader 占 20ms。
# visual_quality=0 跳过：河岸 fbm 扰动 / river flow / shore 4 对角 sample / fbm octave。
# 用户手机 toggle 看 q=2/1/0 各自 FPS 实际差异，再决定是否把 mobile default 锁 0。

func cycle_visual_quality(host) -> void:
	host.visual_quality = (host.visual_quality + 2) % 3  # 2→1→0→2 循环（按下次序符合"渐降"直觉）
	if host._renderer != null and host._renderer.has_method("set_visual_quality"):
		host._renderer.set_visual_quality(host.visual_quality)
	# weather_layer 同步（之前漏了）
	if host._renderer != null:
		var weather_layer_node = host._renderer.get_node_or_null("WeatherLayer")
		if weather_layer_node != null and weather_layer_node.has_method("set_visual_quality"):
			weather_layer_node.set_visual_quality(host.visual_quality)
	print("[render-profile] visual_quality 切换为 %d" % host.visual_quality)



func _mark_debug_console_state_dirty(host) -> void:
	if host._debug_console != null and host._debug_console.has_method("request_state_sync"):
		host._debug_console.call("request_state_sync")




func fit_debug_map(host) -> void:
	if host._camera != null:
		host._camera.fit_to_viewport(1.05, host._map_safe_area())


func toggle_emergent_debug_switches(host) -> void:
	if host._generator == null:
		print("[Emergent+Insolation] generator not ready, ignored.")
		return
	var cp = host._generator._c()
	if cp == null:
		print("[Emergent+Insolation] ClimateProfile missing, ignored.")
		return
	var fallback: bool = bool(cp.emergent_season_enabled)
	var new_state: bool = not fallback
	cp.emergent_season_enabled = new_state
	cp.enable_local_climate_coupling = new_state
	cp.emergent_weather_coupling = new_state
	cp.fast_slow_layering_enabled = new_state
	cp.true_insolation_enabled = true
	print("[Emergent+Insolation] coupling switches → %s; true insolation remains authoritative" % str(new_state))
	if host._renderer != null and host._renderer.has_method("set_true_insolation_enabled"):
		host._renderer.set_true_insolation_enabled(true)
	var ws: Object = host._generator.call("get_weather_system") if host._generator.has_method("get_weather_system") else null
	if ws != null and ws.has_method("configure_emergent_coupling"):
		ws.call("configure_emergent_coupling",
			bool(cp.emergent_weather_coupling),
			float(cp.rain_shadow_threshold),
			float(cp.rain_shadow_factor),
			float(cp.orographic_boost)
		)
	if ws != null and ws.has_method("configure_ocean_spawn_bias"):
		ws.call("configure_ocean_spawn_bias", float(cp.ocean_weather_spawn_bias))
	if host._current_map != null and host._world_clock != null:
		host._generator.refresh_climate_daily(host._current_map, host._world_clock.season_phase())
		host._refresh_emergent_lines()
	host._mark_debug_console_state_dirty()


func toggle_ocean_current_debug(host) -> void:
	if host._renderer != null and host._renderer.has_method("set_ocean_current_debug"):
		var cur: bool = host._renderer.get_ocean_current_debug()
		host._renderer.set_ocean_current_debug(not cur)
		print("[VisualOverhaul] ocean_current_debug = %s" % str(not cur))
	host._mark_debug_console_state_dirty()


static func toggle_data_core_weather_debug(host) -> void:
	# dots-flag-prune-pr1 (2026-05-22)：stub kept for debug_console.gd compatibility.
	print("[DataCore] toggle deprecated: use_data_core_weather flag removed (single-path).")


static func toggle_data_core_master_debug(host) -> void:
	# dots-flag-prune-pr1 (2026-05-22)：stub kept for debug_console.gd compatibility.
	print("[DataCore] toggle deprecated: use_data_core flag removed (single-path).")


func start_soak_dump_debug(host) -> void:
	host._soak_dump_hotkey_start()


func start_soak_ab_same_source_debug(host, n_ticks: int = 30) -> void:
	host._soak_ab_hotkey_start(host.SOAK_AB_MODE_SAME_SOURCE, n_ticks)


func start_soak_ab_vs_legacy_debug(host) -> void:
	host._soak_ab_hotkey_start(host.SOAK_AB_MODE_VS_LEGACY)

# ─── 已删除验收入口（dots-flag-prune-pr1，2026-05-22）──────────────────────
# 以下 debug 入口随 ClimateProfile flag 一同删除：
#   - start_soak_ab_season_round_batch_debug（use_gdext_season_round 已删）
#   - start_soak_ab_sus_scheduler_batch_debug（use_gdext_sus_scheduler 已删）
#   - start_soak_ab_phase_c4_acceptance_debug（依赖 unified_fast_tick /
#     system_schedule / season_round 三个已删 flag 的 batch 入口）
#   - _on_c4_batch_completed / _try_start_next_c4_batch / _c4_acceptance_queue

## DOTS-Total-CPP C.3d/C.3e 直接验收入口：跑两段（30 + 1000 tick）SAME_SOURCE A/B
## （A=use_gdext_thread_fallback off / B=on），覆盖全部 5 个 _thread 入口：
##   climate Pass-B / ocean_water / ocean_land / sea_ice / vegetation_dynamics
## 预期：bit-equal（reduce 严格按 task_idx 升序，无 race），N≥2400 + WTP 可用时
## thread on 略快或持平。

func start_soak_ab_thread_batch_debug(host) -> void:
	var runner_script = host._get_soak_ab_runner_script()
	if runner_script == null:
		print("[main] thread batch ignored: A/B runner script unavailable")
		return
	if runner_script.instance != null and (runner_script.instance.is_running() or runner_script.instance.is_batch_active()):
		print("[main] thread batch ignored: A/B runner already running")
		return
	if runner_script.instance == null:
		runner_script.instance = runner_script.new()
	var ok: bool = runner_script.instance.start_thread_batch(host)
	if not ok:
		print("[main] start_thread_batch failed (generator not ready?)")



func cancel_soak_debug(host) -> void:
	host._soak_ab_hotkey_cancel()


func print_data_core_flags_debug(host) -> void:
	host._print_data_core_flag_snapshot()


func print_validate_weather_snapshot_debug(host) -> void:
	host._validate_weather_print_snapshot()


func print_perf_verdict_debug(host) -> void:
	host.request_dots_final_push_perf_verdict()




func _demo_tg_diag_once(host, reason: String) -> void:
	if host._demo_tg_diag_seen.has(reason):
		return
	host._demo_tg_diag_seen[reason] = true
	push_warning("[demo_thermal_gradient] pass skipped — " + reason)

func _is_demo_thermal_gradient_enabled(host) -> bool:
	if host._generator == null or not host._generator.has_method("_c"):
		return false
	var cp = host._generator._c()
	if cp == null:
		return false
	if not ("demo_thermal_gradient_enabled" in cp):
		return false
	return bool(cp.demo_thermal_gradient_enabled)

func _run_demo_thermal_gradient_pass_if_enabled(host) -> void:
	if not host._is_demo_thermal_gradient_enabled():
		host._demo_tg_diag_once("disabled (ClimateProfile.demo_thermal_gradient_enabled=false or no _c())")
		return
	if host._current_map == null or host._generator == null:
		host._demo_tg_diag_once("no current_map / generator")
		return
	if not host._generator.has_method("get_data_core_world_ext"):
		host._demo_tg_diag_once("generator lacks get_data_core_world_ext (legacy build?)")
		return
	var ext = host._generator.get_data_core_world_ext()
	if ext == null:
		host._demo_tg_diag_once("DCWorldExt is null (gdext not loaded)")
		return  # gdext 未加载（fallback 到纯 GDScript）；此 demo 无 GDScript fallback
	var cp = host._generator._c()
	var gain: float = float(cp.demo_thermal_gradient_elevation_gain) if cp != null else 1.5
	var k: float = float(cp.demo_thermal_gradient_normalize_k) if cp != null else 0.5
	# Pass #3 4 个新旋钮——cp 为空或字段不存在时 fallback 到 C++ 默认值。
	var iter: int = 16
	var kr: int = 2
	var coriolis: float = 0.5
	var drag: float = 0.6
	if cp != null:
		if "demo_complex_iterations" in cp:
			iter = int(cp.demo_complex_iterations)
		if "demo_complex_kernel_radius" in cp:
			kr = int(cp.demo_complex_kernel_radius)
		if "demo_complex_coriolis_strength" in cp:
			coriolis = float(cp.demo_complex_coriolis_strength)
		if "demo_complex_terrain_drag" in cp:
			drag = float(cp.demo_complex_terrain_drag)
	var w: int = int(host._current_map.width)
	var h: int = int(host._current_map.height)
	# ─── 关键：bind_map_data 之后 CoW 已分裂，C++ 端 s.arr_f32 与 GDScript 端
	# map.temp_arr / elevation_arr 不再共享；按 docs/performance-charter §11
	# 的官方契约，GDScript→C++ 必须用 write_f32_range 显式 push。
	# 否则 C++ 永远读到 bind 那一瞬的初值（很可能全 0），输出也就全 0。
	var cid_t: int = int(ext.component_id(&"cell_temp"))
	var cid_e: int = int(ext.component_id(&"cell_elevation"))
	if cid_t >= 0:
		ext.write_f32_range(cid_t, 0, host._current_map.temp_arr)
	if cid_e >= 0:
		ext.write_f32_range(cid_e, 0, host._current_map.elevation_arr)
	# C++ 端读 cell_temp / cell_elevation slot（已由上面的 write_f32_range 同步），
	# 写 cell_demo_thermal_gradient slot，pass 末尾通过 snapshot_f32 取回。
	# Pass #3 测时用 Time.get_ticks_usec()，含 pass 主体 + 不含 snapshot 的两段。
	#
	# ─── DOTS path dispatch ───────────────────────────────────────────
	# `demo_thermal_gradient_path` 三选一（详见 ClimateProfile.DemoTGPath）：
	#   * LEGACY        → 旧手写直调，零调度开销，是 pre-DOTS 基线。
	#   * ECS           → 用 DCEcsScheduler 单 job 跑同一个 kernel；输出与
	#                     LEGACY 路径 bit-equal（kernel 完全相同，只是多一层
	#                     拓扑排序 + Callable 调用）。
	#   * ECS_ARCHETYPE → DCEcsScheduler + run_demo_complex_pass_archetyped
	#                     (target=LAND)。OCEAN cells 输出被置 0；视觉上能
	#                     看到水陆边界，性能差距和 vanilla 相比由 A1 实验
	#                     描述（stencil 类算子收益 ≈ 0）。
	var path_id: int = 0  # default LEGACY
	if cp != null and "demo_thermal_gradient_path" in cp:
		path_id = int(cp.demo_thermal_gradient_path)
	var path_label: String = "legacy"
	var t0_cpp: int = Time.get_ticks_usec()
	if path_id == 0:
		# LEGACY directly runs the same kernel used by the ECS configurations.
		path_label = "legacy"
		ext.run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)
	else:
		# ECS / ECS_ARCHETYPE — both go through DCEcsScheduler.
		path_label = "ecs" if path_id == 1 else "ecs_archetype"
		host._run_demo_tg_via_ecs(ext, w, h, iter, kr, coriolis, drag, gain, k, path_id)
	var cpp_us: int = Time.get_ticks_usec() - t0_cpp
	# 路径首次进入时打一行诊断，方便确认 ClimateProfile 配置生效。
	if not host._dc_ecs_path_label_seen.has(path_label):
		host._dc_ecs_path_label_seen[path_label] = true
		print("[demo_thermal_gradient] dispatch path=%s (path_id=%d)" % [path_label, path_id])
	# CoW 共享下 ptrw 已就地写入；再 snapshot 一次确保 GDScript 侧 detach 安全
	# （避免 CoW 在被 GDScript mutate 后引用别处的副本）。开销 ~ 一次 memcpy。
	var cid: int = int(ext.component_id(&"cell_demo_thermal_gradient"))
	if cid < 0:
		host._demo_tg_diag_once("component_id(cell_demo_thermal_gradient) < 0 — slot not registered")
		return
	var snap: PackedFloat32Array = ext.snapshot_f32(cid)
	host._current_map.demo_thermal_gradient_arr = snap
	# ─── Pass #3 每 tick 耗时打印（紧凑诊断）─────────────────────────
	# 第一次还多打一行 inputs 行（沿用 Pass #2 既有 _demo_tg_first_run_logged 守门）。
	host._demo_complex_tick_counter += 1
	var s_n: int = snap.size()
	var s_min: float = INF
	var s_max: float = -INF
	var s_sum: float = 0.0
	for i in range(s_n):
		var v: float = snap[i]
		if v < s_min: s_min = v
		if v > s_max: s_max = v
		s_sum += v
	var s_mean: float = (s_sum / float(s_n)) if s_n > 0 else 0.0
	var kernel_label: String = "demo_complex"
	var pass_label: String = kernel_label + "/" + path_label
	print("[" + pass_label + "] tick=#" + str(host._demo_complex_tick_counter)
		+ " w=" + str(w) + " h=" + str(h)
		+ " iter=" + str(iter) + " kr=" + str(kr)
		+ " coriolis=" + String.num(coriolis, 3)
		+ " drag=" + String.num(drag, 3)
		+ " cpp=" + str(cpp_us) + " µs"
		+ " out[min=" + String.num(s_min, 4)
		+ " max=" + String.num(s_max, 4)
		+ " mean=" + String.num(s_mean, 4) + "]")
	# 过预算守门：单 tick > 16 ms 仅在第 1 次发生时 push_warning，避免每帧刷屏
	if cpp_us > 16000 and not host._demo_complex_over_budget_warned:
		host._demo_complex_over_budget_warned = true
		push_warning("[" + pass_label + "] cpp=" + str(cpp_us)
			+ " µs > 16 ms budget — consider lowering demo_complex_iterations or kernel_radius")
	# 第一次跑完 pass 后看看输出范围 + 输入范围。
	# 如果输出 max==0 但输入 cell_temp/cell_elevation 也是全 0，说明 climate Pass-A 没填温度场。
	if not host._demo_tg_first_run_logged:
		host._demo_tg_first_run_logged = true
		# 输入端：从 _current_map 读 temp_arr / elevation_arr（这是 GDScript 端
		# 的当前真值；上面已经用 write_f32_range 把它们推给 C++ slot，所以
		# C++ pass 读到的就是这同一份数据）。
		var t_arr: PackedFloat32Array = host._current_map.temp_arr
		var e_arr: PackedFloat32Array = host._current_map.elevation_arr
		var t_min: float = INF; var t_max: float = -INF; var t_sum: float = 0.0
		for i in range(t_arr.size()):
			var tv: float = t_arr[i]
			if tv < t_min: t_min = tv
			if tv > t_max: t_max = tv
			t_sum += tv
		var t_mean: float = (t_sum / float(t_arr.size())) if t_arr.size() > 0 else 0.0
		var e_min: float = INF; var e_max: float = -INF; var e_sum: float = 0.0
		for i in range(e_arr.size()):
			var ev: float = e_arr[i]
			if ev < e_min: e_min = ev
			if ev > e_max: e_max = ev
			e_sum += ev
		var e_mean: float = (e_sum / float(e_arr.size())) if e_arr.size() > 0 else 0.0
		print("[" + pass_label + "] first run OK — input temp[n=" + str(t_arr.size())
			+ " min=" + String.num(t_min, 4) + " max=" + String.num(t_max, 4)
			+ " mean=" + String.num(t_mean, 4) + "] elevation[n=" + str(e_arr.size())
			+ " min=" + String.num(e_min, 4) + " max=" + String.num(e_max, 4)
			+ " mean=" + String.num(e_mean, 4) + "]")


# ─── DOTS thermal-gradient ECS dispatch helpers ───────────────────────
# Build a one-shot scheduler with a single demo_thermal_gradient job and
# tick it. The bit-equal contract is:
#   * ECS path        ≡ LEGACY path (same kernel, scheduler is a pure shim).
#   * ECS_ARCHETYPE   ≠ LEGACY (zeros OCEAN cells; only LAND-cells comparable
#                       and even those are re-normalized — see A1 §2.3).
#
# `path_id` mapping mirrors ClimateProfile.DemoTGPath:
#   1 → ECS, 2 → ECS_ARCHETYPE.

func _run_demo_tg_via_ecs(host, ext: Object, w: int, h: int, iter_count: int, kr: int,
		coriolis: float, drag: float, gain: float, k: float, path_id: int) -> void:
	# Lazy scheduler instantiation — one shared instance across ticks.
	if host._dc_ecs_scheduler == null:
		host._dc_ecs_scheduler = host.DCEcsScheduler.new()

	# ECS_ARCHETYPE: ensure archetypes exist + are assigned from the current
	# water mask. We treat the assignment as one-shot per map (re-done when
	# `_dc_ecs_archetype_dirty` is set externally on regenerate).
	var land_arch_id: int = -1
	if path_id == 2:
		if host._dc_ecs_archetype_dirty or host._dc_ecs_land_archetype_id < 0:
			host._dc_ecs_land_archetype_id = host._dc_ecs_sync_archetypes(ext)
			host._dc_ecs_archetype_dirty = false
		land_arch_id = host._dc_ecs_land_archetype_id

	# Build the single-job graph each tick: comp_ids are stable across ticks
	# but cheap to look up; this keeps the path resilient to mid-game
	# component re-registration if it ever happens.
	var cid_temp: int = int(ext.component_id(&"cell_temp"))
	var cid_elev: int = int(ext.component_id(&"cell_elevation"))
	var cid_out: int = int(ext.component_id(&"cell_demo_thermal_gradient"))
	if cid_temp < 0 or cid_elev < 0 or cid_out < 0:
		host._demo_tg_diag_once("ECS dispatch: component_id < 0 (temp=%d elev=%d out=%d)"
			% [cid_temp, cid_elev, cid_out])
		# Fall back to legacy direct call — never silently no-op.
		ext.run_demo_complex_pass(w, h, iter_count, kr, coriolis, drag, gain, k)
		return

	host._dc_ecs_scheduler.clear()
	var runner: Callable
	var arch_filter: int
	if path_id == 2:
		runner = Callable(host, "_dc_ecs_run_demo_complex_archetyped")
		arch_filter = land_arch_id
	else:
		runner = Callable(host, "_dc_ecs_run_demo_complex")
		arch_filter = -1

	var job := host.DCEcsJob.new(
		&"demo_thermal_gradient",
		[cid_temp, cid_elev],
		[cid_out],
		runner,
		arch_filter,
		{}
	)
	host._dc_ecs_scheduler.add_job(job)

	var ctx: Dictionary = {
		"ext": ext,
		"w": w, "h": h,
		"iter": iter_count, "kr": kr,
		"coriolis": coriolis, "drag": drag,
		"gain": gain, "k": k,
	}
	host._dc_ecs_scheduler.tick(ctx)


# Re-create archetypes (LAND, OCEAN) and assign every cell from
# `_current_map.is_water_arr`. Returns the LAND archetype id.
# Called only when `_dc_ecs_archetype_dirty` flips true (initial entry +
# after map regenerate).

func _dc_ecs_sync_archetypes(host, ext: Object) -> int:
	var land_id: int = int(ext.create_archetype(&"LAND", []))
	var ocean_id: int = int(ext.create_archetype(&"OCEAN", []))
	if host._current_map == null:
		return land_id
	var mask: PackedByteArray = host._current_map.is_water_arr
	var n: int = mask.size()
	# ─── BUGFIX: C++-side `_entity_count` must be ≥ n before assign_archetype ───
	# Production path never calls `ext.create_pool("cells", n)` (only the bench
	# does). DCWorldExt::assign_archetype silently drops `idx >= _entity_count`,
	# leaving `_entity_archetype` empty; the archetyped pass then early-returns
	# with a `_entity_archetype size < n` warning and writes nothing → overlay
	# all-zero. Top up entity_count to n here. `create_entities` is additive,
	# so guard against the rare case where front-pool or future systems already
	# pushed it past n.
	var ec: int = int(ext.entity_count())
	if ec < n:
		ext.create_entities(n - ec)
	for i in range(n):
		if mask[i] != 0:
			ext.assign_archetype(i, ocean_id)
		else:
			ext.assign_archetype(i, land_id)
	print("[demo_thermal_gradient/ecs_archetype] archetypes synced — "
		+ "n=" + str(n)
		+ " entity_count_before=" + str(ec)
		+ " entity_count_after=" + str(ext.entity_count())
		+ " land_id=" + str(land_id) + " ocean_id=" + str(ocean_id))
	return land_id


# Job runners (Callable targets). Signature: (ctx, job) -> void.

func _dc_ecs_run_demo_complex(host, ctx: Dictionary, _job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]))

func _dc_ecs_run_demo_complex_archetyped(host, ctx: Dictionary, job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass_archetyped(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]),
		int(job.archetype_filter))

func diagnose_ocean_heat(host) -> void:
	if host._current_map == null:
		print("[Ocean] diagnose: no map")
		return
	var mn: float = INF
	var mx: float = -INF
	var sm: float = 0.0
	var cnt: int = 0
	var hot_water: int = 0
	var hot_land: int = 0
	for c: HexCell in host._current_map.all_cells():
		var a: float = c.temperature_transport_anomaly
		mn = minf(mn, a)
		mx = maxf(mx, a)
		sm += a
		cnt += 1
		if absf(a) > 0.02:
			if c.ocean_current.length_squared() > 1e-6:
				hot_water += 1
			else:
				hot_land += 1
	if cnt > 0:
		print("[Ocean] heat_debug: anomaly min=%.3f max=%.3f mean=%.4f | |a|>0.02: water=%d land=%d" % [
			mn, mx, sm / float(cnt), hot_water, hot_land
		])

# 诊断动作：打印当前选中地块的 temperature_breakdown（展开成详细项）。

func diagnose_selected_temperature(host) -> void:
	if host._selected_cell == null:
		print("[Temp] diagnose: no selection")
		return
	var cell := host._selected_cell
	# B.1：通过 ViewAdapter 读 schema-mirrored 字段
	var diag_idx: int = int(cell.index)
	var diag_ad: DCViewAdapter = host._view_adapter
	var diag_t: float = diag_ad.get_temp(diag_idx) if diag_ad != null else float(cell.temperature)
	var diag_b: float = diag_ad.get_temp_baseline(diag_idx) if diag_ad != null else float(cell.temp_baseline)
	var diag_s: float = diag_ad.get_temp_season_offset(diag_idx) if diag_ad != null else float(cell.temp_season_offset)
	print("[Temp] cell(q=%d,r=%d) temperature=%.3f baseline=%.3f season_off=%.3f" % [
		cell.q, cell.r, diag_t, diag_b, diag_s
	])
	var bd: Dictionary = cell.temperature_breakdown
	if bd.is_empty():
		print("    (breakdown empty — selected cell not yet sampled this tick)")
	else:
		for k in bd.keys():
			print("    %s = %.3f" % [str(k), float(bd[k])])

func get_selected_cell(host) -> HexCell:
	return host._selected_cell

func get_current_map(host) -> MapData:
	return host._current_map

func get_world_clock_ref(host) -> WorldClock:
	return host._world_clock

func get_generator(host) -> MapGenerator:
	return host._generator

func get_renderer(host) -> HexRenderer:
	return host._renderer

func get_fast_tick_count(host) -> int:
	return host._fast_tick_count

func get_last_fast_tick_ms(host) -> int:
	return host._overlay_last_fast_tick_ms

func get_sus_last_tick_report(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("sus_report_last_tick"):
		return {}
	var report: Dictionary = host._generator.sus_report_last_tick()
	return report.duplicate(false)

func get_sus_last_tick_summary(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("sus_report_last_tick_summary"):
		return {}
	var summary: Dictionary = host._generator.sus_report_last_tick_summary()
	return summary.duplicate(false)

func _parse_data_core_cli(host) -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	# 同时接受工程 cmdline_args（编辑器测试 / Godot 启动参数）
	for a in OS.get_cmdline_args():
		args.append(a)
	for arg in args:
		var s: String = String(arg)
		match s:
			"--data-core", "--no-data-core", \
			"--data-core-weather", "--no-data-core-weather", \
			"--validate-weather":
				print("[DataCore] %s deprecated: flag removed (single-path); ignored." % s)
			_:
				# 形如 --soak-dump=30 / --soak-dump=30:full:user://x.jsonl
				if s.begins_with("--soak-dump="):
					host._cli_soak_dump_arg = s.substr("--soak-dump=".length())


# 应用阶段：generator 已创建。dots-flag-prune-pr1 后 ClimateProfile 已无相关
# flag；本函数仅保留 --soak-dump 启动逻辑（独立于 flag 表）。

func _apply_data_core_cli_to_profile(host) -> void:
	if host._generator == null:
		return
	# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：CLI 启动 N tick dump。
	# generator 已经 _generate_and_render 完成，map / world 都就绪；hot path
	# 第一次跑（climate_daily_system._finalize_round）就会写第一条记录。
	if host._cli_soak_dump_arg != "":
		var dump_script = host._get_soak_dump_script()
		if dump_script == null:
			push_warning("[main] --soak-dump=%s ignored: DCSoakDump script unavailable" % host._cli_soak_dump_arg)
			return
		if dump_script.instance == null:
			dump_script.instance = dump_script.new()
		var ok: bool = dump_script.instance.start_from_arg(host._cli_soak_dump_arg, host._generator)
		if not ok:
			push_warning("[main] --soak-dump=%s failed to start (see prior errors)" % host._cli_soak_dump_arg)


## 调试 / Overlay：生成 DataCore 状态摘要供 SUS 周期日志附加。

func _soak_dump_hotkey_start(host) -> void:
	if host._generator == null:
		print("[soak-dump] F2: generator not ready, ignored.")
		return
	var dump_script = host._get_soak_dump_script()
	if dump_script == null:
		push_warning("[soak-dump] F2 ignored: DCSoakDump script unavailable")
		return
	if dump_script.instance != null and dump_script.instance.is_active():
		print("[soak-dump] F2: already running, ignored. (active=%s)" % str(dump_script.instance.is_active()))
		return
	if dump_script.instance == null:
		dump_script.instance = dump_script.new()
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://soak/manual_%s.tsv" % ts
	var ok: bool = dump_script.instance.start(30, host.SOAK_DUMP_MODE_SUMMARY, path, host._generator)
	if ok:
		print("[soak-dump] F2 started: 30 ticks → %s" % path)
	else:
		push_warning("[soak-dump] F2 start failed (see prior errors)")

func _get_soak_dump_script(host) -> GDScript:
	if host._soak_dump_script != null:
		return host._soak_dump_script
	if host._soak_dump_load_attempted:
		return null
	host._soak_dump_load_attempted = true
	if not ResourceLoader.exists(host.SOAK_DUMP_SCRIPT_PATH):
		push_warning("[soak-dump] script missing: %s; dump tools disabled." % host.SOAK_DUMP_SCRIPT_PATH)
		return null
	host._soak_dump_script = load(host.SOAK_DUMP_SCRIPT_PATH) as GDScript
	if host._soak_dump_script == null:
		push_warning("[soak-dump] script failed to load: %s; dump tools disabled." % host.SOAK_DUMP_SCRIPT_PATH)
	return host._soak_dump_script

func _get_soak_ab_runner_script(host):
	if host._soak_ab_runner_script != null:
		return host._soak_ab_runner_script
	if host._soak_ab_runner_load_attempted:
		return null
	host._soak_ab_runner_load_attempted = true
	if host._get_soak_dump_script() == null:
		push_warning("[soak-ab] runner disabled: DCSoakDump script unavailable.")
		return null
	if not ResourceLoader.exists(host.SOAK_AB_RUNNER_SCRIPT_PATH):
		push_warning("[soak-ab] runner script missing: %s; A/B tools disabled." % host.SOAK_AB_RUNNER_SCRIPT_PATH)
		return null
	host._soak_ab_runner_script = load(host.SOAK_AB_RUNNER_SCRIPT_PATH) as GDScript
	if host._soak_ab_runner_script == null:
		push_warning("[soak-ab] runner script failed to load: %s; A/B tools disabled." % host.SOAK_AB_RUNNER_SCRIPT_PATH)
	return host._soak_ab_runner_script


# ─── DCSoakABRunner Hotkey (F3) ──────────────────────────────────────────
# 一键完整 A/B 对比工作流：
#   1) 用当前 DataCore 状态跑 N tick → phase A.tsv
#   2) (VS_LEGACY) toggle DataCore master / (SAME_SOURCE) 不切换
#   3) 跑 N tick → phase B.tsv
#   4) 内置 diff 报告（max mean_diff per field, top-15）
# 总耗时 ≈ 2N sim-ticks（按游戏速度档：x1 ≈ 60s/30tick, x5 ≈ 12s, x20 ≈ 3s）。
# 已在跑则忽略；建议在游戏速度 ≥ x5 时按以缩短总耗时。
#
# B3b 阶段 3 收工长期验收用 Ctrl+F3 → n_ticks=1000；在 x20 速度下 ≈ 100s。

func _soak_ab_hotkey_start(host, mode: int = SOAK_AB_MODE_SAME_SOURCE,
		n_ticks: int = 30) -> void:
	if host._generator == null:
		print("[soak-ab] F3: generator not ready, ignored.")
		return
	var runner_script = host._get_soak_ab_runner_script()
	if runner_script == null:
		push_warning("[soak-ab] F3 ignored: A/B runner script unavailable")
		return
	if runner_script.instance != null and runner_script.instance.is_running():
		print("[soak-ab] F3: already running, ignored. (Alt+F3 取消当前流程)")
		return
	if runner_script.instance == null:
		runner_script.instance = runner_script.new()
	var ok: bool = runner_script.instance.start(host, n_ticks, mode)
	if not ok:
		push_warning("[soak-ab] F3 start failed (see prior errors)")


## Alt+F3 — 立即 cancel 当前 A/B 流程并 stop dump。
## 反卡死（2026-05-17）：当 dumper 自身把 weather wall 拉到 ~40ms+ 顶满 frame budget
## 导致 climate phase 长期 dep_pending starve、_remaining 不递减、dump 永不结束时，
## 用户可按 Alt+F3 强制解卡。同时 dump 内置 stall 守门会在 200 次同 day record 后
## 自动 abort（约 8s @ 40ms/tick），Alt+F3 是更快的手动出口。

func _soak_ab_hotkey_cancel(host) -> void:
	var runner_script = host._get_soak_ab_runner_script()
	if runner_script != null and runner_script.instance != null and runner_script.instance.is_running():
		runner_script.instance.cancel()
		print("[soak-ab] Alt+F3: A/B runner cancelled by user")
		return
	var dump_script = host._get_soak_dump_script()
	if dump_script != null and dump_script.instance != null and dump_script.instance.is_active():
		dump_script.instance.stop()
		print("[soak-ab] Alt+F3: standalone DCSoakDump stopped by user")
		return
	print("[soak-ab] Alt+F3: nothing active to cancel")


## DCSoakABRunner 用 helper：返回当前 use_data_core 状态。
## main.gd 暴露给 runner 用，避免 runner 自己解析 ClimateProfile。
##
## dots-flag-prune-pr1 (2026-05-22)： use_data_core flag 已删除——DataCore 现
## 恒挂载，本 helper 返回常量 true（generator/world 未就绪时返 false作为 probe）。

func is_data_core_on(host) -> bool:
	if host._generator == null:
		return false
	return true


# ─── DataCore Runtime Hot Toggles \u00b7 deprecated stubs ───────────────────
# dots-flag-prune-pr1 (2026-05-22)\uff1a use_data_core / use_data_core_weather flag
# 已删除——DataCore 现恒走单路径，原有 F9/F10 hot-toggle / F11 snapshot 改为
# 简化 stub。F11 仍打 world bind / entity / component 状态，便于 runtime 自检。

func _toggle_data_core_weather_runtime(host) -> void:
	print("[DataCore] toggle deprecated: use_data_core_weather flag removed (single-path).")

func _toggle_data_core_master_runtime(host) -> void:
	print("[DataCore] toggle deprecated: use_data_core flag removed (single-path).")

func _rebuild_view_adapter(host) -> void:
	if host._current_map == null:
		host._view_adapter = null
		return
	# 默认走 Cell（legacy 兼容路径）
	var adapter_kind: String = "Cell"
	# 如果 use_world_view_adapter=true 且 DCWorld 已就绪 → 走 World
	var cp = host._generator._c() if host._generator != null else null
	if cp != null and DCFeatureFlags.is_on(&"use_world_view_adapter", cp):
		var dc_world = host._generator.get_data_core_world() if host._generator != null and host._generator.has_method("get_data_core_world") else null
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			# 修复 A（2026-05-14）：传入 _current_map 让 adapter 直读 map.<field>，
			# 避开 GDExtension CoW 后 view 缓存陈旧 → UI "极寒" bug。
			# 详见 docs/architecture/migration.md storage A/B 同源契约。
			host._view_adapter = DCViewAdapter.World.new(dc_world, host._current_map)
			adapter_kind = "World"
		else:
			push_warning("[main] use_world_view_adapter=true but DCWorld not bound; falling back to Cell adapter")
			host._view_adapter = DCViewAdapter.Cell.new(host._current_map.iter_cells())
	else:
		host._view_adapter = DCViewAdapter.Cell.new(host._current_map.iter_cells())
	# 0.4.2 — view adapter 重建后同步推给 info panel controller。
	if host._info_panel_controller != null:
		host._info_panel_controller.set_view_adapter(host._view_adapter)
	if OS.is_debug_build():
		print("[main] view adapter rebuilt: kind=%s | %s" % [adapter_kind, host._view_adapter.describe()])


# PR-3.4.1（M4 拆分）：_on_dcflag_changed 已迁至 DCDotsBootstrap；
# main 通过 _dots_bootstrap 委派持有 signal connection 生命周期。


# ─── Splash overlay（移动端开场加载体感修复）─────────────────────────────────
#
# 问题：bake_world 同步耗时 ~13s（620k 像素 × GDScript 双重循环 × FastNoiseLite
# 4 频段），期间主线程被占用，UI 完全黑屏。移动端用户体感"应用挂了"。
#
# 当前路径：
#   1. _ready() 入口建一个 CanvasLayer + Label 显示"正在生成世界…"
#   2. `_generate_and_render()` await `MapGenerator.generate()`；generator/baker 在重阶段
#      边界协作式让帧，窗口事件、动画和阶段进度都能继续推进。
#   3. generate 返回后 hide。
#
# 期间 baker.stage_progress 信号也会被订阅并 print，便于诊断；UI 不实时变化是
# 因为主线程被同步 bake 占满，未来 main 把 bake_world 改成 deferred / 协程
# 切片后才能让 UI 跟着 stage 切换。
#
# 后续可优化方向（不在本次 PR 内）：
#   - 把 _bake_height_biome_moisture 写 C++ kernel（预期 7.2s → ~250ms）
#   - 按 seed 缓存 bake 产物到 user://，重启秒进
#   - Use Engine.process_frame await 让 baker 内部按 chunk yield，UI 真正更新

# Mobile UI safe area helper：圆角屏幕 / 高刘海机型 TopBar 被切问题（2026-06-14）。
# 桌面环境完全不动；只在 OS.has_feature("mobile") 时下移 TopBar 并加大按钮。

# G5 responsibility adapters. Mutable state remains in this host.
