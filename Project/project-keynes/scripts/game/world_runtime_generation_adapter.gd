extends RefCounted

## Passive generation/worker preparation adapter.

func _prepare_world_data(host) -> Dictionary:
	var seed_override: int = host._session_prepare_options.seed
	host._runtime_ready_for_ticks = false
	host._ideology_refresh_pending_day = -1
	host._ideology_instance_refreshed_day = -1
	host._ideology_derived_pumped_day = -1
	# 生成后阶段（渲染绑定 + 植被层 + 建筑外观）的进度游标复位：
	# 0.0 表示"本次生成还没进入后期阶段"，_loading_visual_step 在复位前不会发进度。
	host._visual_progress = 0.0
	host._clear_climate_capacity_pending()
	host._runtime_commit_generation = 0
	host._runtime_commit_day = -1
	host._runtime_commit_family_cursors.clear()
	host._runtime_commit_family_done.clear()
	host._runtime_pending_visual_generation = 0
	host._runtime_pending_dirty_families = 0
	host._runtime_last_commit.clear()
	host._runtime_natural_resource_last_commit_day = 0
	host._runtime_natural_resource_pending_target_day = -1
	host._runtime_natural_resource_last_result.clear()
	host._runtime_military_last_commit_day = -1
	host._runtime_military_pending_target_day = -1
	host._runtime_military_last_result.clear()
	host._runtime_military_ms = 0.0
	host._military_vision_render_revision = -1
	host._military_vision_source_slot = -2
	host._military_vision_source_cells = PackedInt32Array()
	host._military_terrain_season_index = -1
	host._country_worker_read_generation = 0
	host._country_worker_read_last_day = -1
	host._country_worker_read_last_result.clear()
	host._country_worker_read_patch_count = 0
	host._country_worker_read_full_snapshot_count = 0
	host._country_worker_read_rejected_count = 0
	host._country_read_last_full_snapshot = false
	host._country_read_last_applied_cells = 0
	host._country_read_last_territory_changed_cells = 0
	host._country_visual_refresh_pending = false
	host._country_visual_refresh_deferred_frames = 0
	host._country_visual_refresh_run_count = 0
	host._country_visual_refresh_defer_count = 0
	host._country_visual_last_refresh_ms = 0.0
	host._sched_proc_country_visual_ms = 0.0
	host._selected_cell = null
	host.clear_map_overlay()
	host.world_generation_started.emit()
	if not host._session_preparation_active():
		return host._session_preparation_failure()
	if host._generator != null and host._generator.has_method("sus_reset_all"):
		host._generator.sus_reset_all()

	host._apply_world_setup_base_config()
	host._apply_feature_flags()

	var cfg = MapConfig.make(host.map_width, host.map_height)
	cfg.num_continents = host.num_continents
	cfg.continent_size = host.continent_size
	cfg.sea_level = host.sea_level
	cfg.river_count = host.river_count
	cfg.seed = seed_override if seed_override >= 0 else host.initial_seed
	host._apply_pkmap_override(cfg)

	host._generator = MapGenerator.new()
	host._generator.set_test_economy_bootstrap_enabled(host.generate_test_economy_data)
	host._generator.set_test_economy_population_scale(host.test_economy_population_scale)
	host._generator.set_save_restore_preparation_enabled(not host._pending_load_bundle.is_empty())
	if not host._new_game_config.is_empty():
		host._generator.set_gameplay_start_config(host._new_game_config)
	host._apply_runtime_climate_profile(host._generator)
	if host._world_clock != null:
		host._generator.set_world_clock_ref(host._world_clock)
	if host._generator.has_signal("bake_progress") and not host._generator.bake_progress.is_connected(host._on_baker_stage_progress):
		host._generator.bake_progress.connect(host._on_baker_stage_progress)

	# ── 生成前自检（mapgen preflight）────────────────────────────────────
	# dots-total-cpp 之后地图生成 100% 在 C++、GDScript 无回退：扩展没加载 /
	# native_generation_mode 没开 / 原生方法缺失 这三种情况是"必然失败"，
	# 以前要等玩家盯着进度条几十秒才拿到一个 "map_generator_failed" 码。
	# 现在几毫秒内点名，并直接产出可复制的失败详情（含该缺什么）。
	var preflight: Dictionary = host._generator.generation_preflight()
	if not bool(preflight.get("ok", true)):
		print("[mapgen][preflight] BLOCKED %s" % JSON.stringify(preflight, "", true))
		host._current_map = null
		host._world_data = null
		host._view_adapter = null
		host._report_world_generation_failure(preflight)
		return host._session_preparation_failure()
	print("[mapgen][preflight] ok platform=%s/%s extension_loaded=%s native_mode=%d bound=%s"
		% [
			String(preflight["env"].get("platform", "?")), String(preflight["env"].get("arch", "?")),
			str(preflight.get("extension_loaded", false)), int(preflight.get("native_mode", -1)),
			str(preflight.get("world_ext_bound", false)),
		])

	var result: Dictionary = await host._generator.generate(cfg, host.hex_size)
	if not host._session_preparation_active():
		return host._session_preparation_failure()
	if result.is_empty() or not result.has("map") or not result.has("world_data"):
		host._current_map = null
		host._world_data = null
		host._view_adapter = null
		host._report_world_generation_failure()
		return host._session_preparation_failure()
	if not host._new_game_config.is_empty():
		var start_report: Dictionary = host._generator.gameplay_start_report()
		if not bool(start_report.get("ok", false)):
			host._current_map = null
			host._world_data = null
			host._view_adapter = null
			# 这条失败不来自 MapGenerator（地图已经生成好了），必须自建诊断记录，
			# 否则会落到"地图生成器返回空结果"的兜底文案上，误导排查方向。
			# [start-report 2026-11-02] 只给一句"开局初始化失败"没法排查：把
			# gameplay_start_report 的关键字段（code/reason/cell/seed/地图尺寸 + 其余
			# 标量键）塞进 hint，失败面板和落盘文件里直接能看到。
			var report_bits: PackedStringArray = PackedStringArray()
			for key in start_report.keys():
				var value = start_report[key]
				var text = str(value)
				if text.length() > 120:
					text = text.substr(0, 120) + "…"
				report_bits.append("%s=%s" % [String(key), text])
			host._emit_world_generation_failure("gameplay_bind", "gameplay_start_failed",
				String(start_report.get("message", "开局初始化失败。")),
				"开局初始化是玩法层失败（地图本身已生成）。gameplay_start_report：%s"
					% " ".join(report_bits))
			return host._session_preparation_failure()

	host._current_map = result["map"] as MapData
	host._building_visual_intel.configure(
		host._current_map.cell_count() if host._current_map != null else 0)
	host._building_visual_diag_logged = false
	host._world_data = result["world_data"] as WorldData
	host._last_seed = int(result.get("seed", cfg.seed))
	# 生成出的世界只能用它实际使用的 seed 复现。`generate_world(0)`（失败重试 /
	# 调试重生成）会把 0 解析成随机 seed，若会话配置仍记录旧 seed，之后写出的
	# 存档就是「旧 seed + 另一张世界的 PKCN/领土」，下次读档会在
	# `_player_start_cell_drift()` 处必然失败。这里把生效 seed 回写进会话配置。
	host._adopt_generated_seed(host._last_seed)
	host._fast_tick_count = 0
	host._last_fast_tick_ms = 0
	host._last_tick_timing.clear()
	host._last_recorder_perf_summary.clear()
	host._last_ui_perf_summary.clear()
	host._pending_tick_start_usec = 0
	if host._world_clock != null:
		host._generator.set_world_clock_ref(host._world_clock)
	host._rebuild_view_adapter()
	return {"ok": true}


func _prepare_world_presentation(host) -> Dictionary:
	return await preload("res://scripts/game/world_runtime_preparation.gd").prepare_presentation(
		host._session_prepare_options.safe_area, host._bind_renderer_and_camera,
		host._session_preparation_active, host._session_preparation_failure, host._session_frames,
		host._advance_visual_progress, host._loading_visual_step,
		host._defer_building_visual_catalog_after_ready, host.refresh_building_visual_catalog)


func _prepare_world_restore(host) -> Dictionary:
	return preload("res://scripts/game/world_runtime_restore_preparation.gd").prepare(
		host._pending_load_bundle, host._generator, host._current_map, host._restore_prepared_world,
		host._world_clock, host._session_prepare_options, host._emit_world_generation_failure,
		host._session_preparation_failure)

func _restore_prepared_world(host) -> Dictionary:
	var save_service = host._game_save_service()
	return save_service.restore_prepared_game(host) if save_service != null \
		else {"ok": false, "message": "存档服务不可用。"}

func _prepare_world_simulation(host) -> Dictionary:
	# Fresh worlds freeze here; loads first install committed climate state.
	# Web 曾经在这里跳过 capture（当时日志停在 _bind_country_visuals 之后、心跳全停）。
	# 真正原因是首帧 shader 编译 45s 堵住整帧，不是 capture 本身。ACTIVE worker
	# 需要这份输入快照，所以恢复。
	if host._load_slot_id.is_empty() and host._generator != null and host._generator.has_method("capture_runtime_inputs_for_worker"):
		# The first worker plan runs the day after the saved calendar day.
		var capture_day := int(host._world_clock.day_index()) + 1 \
			if host._world_clock != null else -1
		var input_capture: Dictionary = host._generator.capture_runtime_inputs_for_worker(
			capture_day)
		if not bool(input_capture.get("ok", false)):
			push_warning("[runtime-input] capture deferred: %s" % String(
				input_capture.get("code", "unknown")))
	if host._generator != null and host._generator.has_method("capture_country_worker_inputs"):
		host._country_worker_transport_capture = host._generator.capture_country_worker_inputs()
		if not bool(host._country_worker_transport_capture.get("ok", false)):
			push_warning("[country-worker] capture deferred: %s" % String(
				host._country_worker_transport_capture.get("code", "unknown")))
	host._loading_visual_step("start_worker")
	WebTelemetry.emit("bind_step", {"s": "start_worker_step"})
	# Web：这一帧是「第一次真正把地图画出来」，实测在 ANGLE 上要 45s（探针已排除
	# 世界材质与迷雾 shader，属于首次 GPU 上传/驱动编译的合成开销）。把它放在
	# `world_ready` 之前会让加载条卡在 98% 几十秒；放到之后，玩家先进世界，
	# 这一帧变成一次性顿挫（不影响日历，后续帧 ~16ms）。
	if not OS.has_feature("web"):
		await host._session_frames.next_frame()
		if not host._session_preparation_active():
			return host._session_preparation_failure()
	WebTelemetry.emit("bind_step", {"s": "post_worker_frame"})
	var annual_handle: int = host._resolve_player_country_handle()
	# Annual reports depend on the Country + Economy + Ideology catalogs.  A
	# failed economy bootstrap leaves those providers intentionally absent; keep
	# the session diagnostic at its original failure point and do not emit a
	# second initialization error from this optional report module.
	var annual_ideology_ready: bool = host._generator != null \
		and host._generator.has_method("get_ideology_facade") \
		and host._generator.get_ideology_facade() != null
	if annual_handle != 0 and annual_ideology_ready:
		var annual_result: Dictionary = host._annual_reports.configure(host._generator, host._world_clock, annual_handle)
		WebTelemetry.emit("bind_step", {"s": "annual_configured"})
		if not bool(annual_result.get("ok", false)):
			push_error("年度报告初始化失败：%s" % String(annual_result.get("reason", "未知原因")))
		if not host._annual_reports.report_ready.is_connected(host._on_annual_report_ready):
			host._annual_reports.report_ready.connect(host._on_annual_report_ready)
	host._start_production_shadow_worker()
	if not host._load_slot_id.is_empty(): host._apply_climate_writeback_if_authoritative(host._generator.get_runtime_thread_report())
	if host._is_web_build() and host._runtime_worker_fault_paused:
		return {"ok": false, "code": host._web_worker_start_code}
	host._clock_binding.attach(host._world_clock, host._generator.set_runtime_clock_threaded,
		host._runtime_session.set_running)
	WebTelemetry.emit("bind_step", {"s": "worker_skipped"})
	var initial_visible_building_cells = PackedInt32Array()
	for cell in host._current_map.cell_count():
		if cell < host._current_map.visible_arr.size() and host._current_map.visible_arr[cell] != 0:
			initial_visible_building_cells.append(cell)
	WebTelemetry.emit("bind_step", {"s": "visible_cells_scanned", "n": initial_visible_building_cells.size()})
	host._refresh_building_visual_intel({
		"newly_visible_cells": initial_visible_building_cells,
		"vision_revision": host._current_map.vision_revision,
	})
	WebTelemetry.emit("bind_step", {"s": "intel_refreshed"})
	host._loading_visual_step("visual_done")
	# Web：同样把这一帧让给 `world_ready` 之后——第一次真正绘制的 ~45s 已经确认
	# 不是世界材质 / 迷雾 shader（两个探针都排除），是首次 GPU 上传/驱动合成的
	# 一次性开销。放在 ready 之后就变成"先进世界，随后一次性顿挫"，而不是把
	# 加载条钉在 98%。
	if not OS.has_feature("web"):
		await host._session_frames.next_frame()
		if not host._session_preparation_active():
			return host._session_preparation_failure()
	return {"ok": true}


func _session_preparation_active(host) -> bool:
	return not host._exiting_tree and host.is_inside_tree() and host._runtime_session.is_preparing()


func _session_preparation_failure(host) -> Dictionary:
	return {"ok": false, "code": "session_cancelled" if not host._session_preparation_active()
		else String(host.last_world_generation_error.get("reason", "world_prepare_failed"))}


func _start_production_shadow_worker(host) -> void:
	# 决策留痕：这一行是 web 上"worker 为什么起不来"的第一现场。
	# 之前它不打印，只能靠 diag 反推，代价是一整轮排查。
	print("[runtime-worker] decide web=%s web_worker=%s inline_requested=%s meta=%s env=%s runtime_native_daily_inline=%s fallback=%s shadow_on_generate=%s" % [
		str(host._is_web_build()),
		str(host._web_worker_requested()),
		str(host._native_daily_inline_requested()),
		str(Engine.get_meta("pk_web_worker", false)),
		str(OS.get_environment("PK_WEB_WORKER")),
		str(host.runtime_native_daily_inline),
		str(host._web_worker_inline_fallback),
		str(host.runtime_shadow_on_generate)])
	if not host.runtime_shadow_on_generate:
		if host._reject_web_daily_fallback("web_native_executor_disabled", "原生执行器启动已关闭"):
			return
		print("[runtime-worker] skipped: runtime_shadow_on_generate=false")
		return
	if host._generator == null or not host._generator.has_method("start_runtime_worker"):
		if host._reject_web_daily_fallback("web_native_start_api_missing", "缺少原生启动接口"):
			return
		print("[runtime-worker] skipped: generator or start_runtime_worker unavailable")
		return
	# ── web 的两种执行者先算清楚，再决定要不要进下面这段 ──────────────
	#
	# 关键：**「内联」也是由本函数启动的**（config["native_daily_inline"]=true 时
	# host 不 spawn 线程，日屏障由调用线程执行）。所以这里**不能**写成
	# `if web and not worker: return` —— 那会把内联也一起关掉，web 默认路径
	# 就只剩 GDScript SUS 日 tick（`day_cost.inl=0 / s2>0`，日历推不动）。
	# 早退只有一个合法理由：web 上两种执行者都不要。
	var web_wants_worker = host._web_worker_requested()
	var web_wants_inline = host._native_daily_inline_requested()
	if host._is_web_build() and not web_wants_worker and not web_wants_inline:
		if host._reject_web_daily_fallback("web_native_executor_not_requested", "worker 与 inline 均未请求"):
			return
		print("[runtime-worker] web build: neither worker nor inline requested; " +
			"GDScript daily tick drives the calendar")
		return
	# B8-4：先解析策略，再决定 worker 以什么模式启动。requested 是会话请求，
	# effective 才是本机/本地图真实生效的模式；诊断里两者都保留。
	var authority_policy: Dictionary = host._resolve_climate_authority_policy()
	var climate_authority_active = bool(authority_policy.get("enabled", false))
	# web 上没有 ACTIVE 就没有 worker/inline 可言（内联日本身要求 ACTIVE，
	# host 会用 `inline_daily_requires_active` 拒绝）。这时保持既有的
	# GDScript SUS 日 tick，**不要** spawn 一个 SHADOW 线程陪跑。
	if host._is_web_build() and not climate_authority_active:
		if host._reject_web_daily_fallback("web_climate_authority_disabled",
				"气候权威已关闭：%s" % String(authority_policy.get("reason", "unknown"))):
			return
		host._web_worker_start_code = "authority_policy_disabled:%s" % String(
			authority_policy.get("reason", "unknown"))
		print("[runtime-worker] web build: climate authority disabled (%s); " +
			"worker not started, GDScript daily tick drives the calendar" \
			% String(authority_policy.get("reason", "unknown")))
		return
	# Web 不再强制降级：那次"worker 图 commit 不了 day"的实际原因是首帧 shader 编译
	# 45s 把整帧堵住（见 docs/web-export.md §9）。shader 裁剪后 ACTIVE 正常工作。
	# 只有 ACTIVE 才推进日历；SHADOW 会停在 day 1。
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	# Web worker 依赖主线程预发布器的两个只读探测 API。旧 side module
	# （例如使用 `skip-native` 导出，或浏览器缓存了旧包）可能仍能加载并报告
	# `requested=ACTIVE`，但没有这两个方法；继续走 worker 会让它停在 PAUSED
	# 等环境帧，而发布权又无法安全交给预发布器，最终把第 1 天钉死。
	# 在启动边界直接切到同一 host 的 inline 日屏障，避免进入这个半启动状态。
	if host._is_web_build() and web_wants_worker and not host._environment_prefetch_capable():
		print("[runtime-worker] web side module lacks environment prefetch API; " +
			"forcing native_daily_inline (rebuild Web native module to re-enable worker)")
		host._web_worker_inline_fallback = true
		web_wants_worker = false
		web_wants_inline = true
	if ext != null and host.runtime_parity_forcing:
		ext.set_runtime_climate_parity_forcing(true)
	host._runtime_climate_writeback_generation = 0
	host._runtime_climate_writeback_days = 0
	host._runtime_climate_writeback_last_day = -1
	# A new worker lifetime restarts Ideology snapshot generations at 1.
	host._ideology_worker_snapshot_generation = 0
	var config: Dictionary = {
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		# A worker lifetime resumes on the calendar the host is already on. This used
		# to be a hardcoded 0, which is only right for a FRESH world: a policy flip
		# stops the worker and calls straight back in here (`_restart_worker_with_
		# current_policy`), so the restarted worker was told to replay from day 0 while
		# every domain pod and every domain store was still at the day it stopped on.
		# The first replayed day then either soft-skips forever (`plan.day <=
		# committed`) or faults the Climate kernel (`climate_day_not_monotonic`), and
		# because the authority grant is deferred until a day commits, the reported
		# mask stayed 0x000 for the rest of the session.
		"day": host._world_clock.day_index() if host._world_clock != null else 0,
		"speed_days_per_second": 1.0,
		"paused": true,
		"events_probe_enabled": host.runtime_events_probe_enabled,
		"economy_execution_mode": host.runtime_economy_execution_mode,
	}
	# Phase-2.4.5: StageOps is the production writer unless parity probe mode
	# (ACTIVE_WITH_PARITY cannot share mutate StageOps with compact).
	# Phase-2.6.1: auto-promote POD_ACTIVE after complete committed mirror.
	if String(host.runtime_economy_execution_mode) != "ACTIVE_WITH_PARITY":
		config["economy_stage_ops_mutate"] = true
		config["economy_production_writer"] = "stage_ops"
		# Host requests auto POD_ACTIVE. The worker records the flag only;
		# WorldRuntimeHost performs the actual switch on an idle boundary.
		config["economy_auto_pod_active"] = host.runtime_economy_auto_pod_active
	if climate_authority_active:
		# graph_coverage_complete 在 per-domain ACTIVE 下的含义是"请求的这些域
		# 线程安全"，不是整图。
		# Player/default play requests the full graph (0xFFF) so Trigger/Effect/
		# Economy are worker-owned. Focused Climate|Country|COMMIT (0x806) remains
		# available by setting runtime_authority_domain_mask for soaks/debug.
		# Phase 2-6：Economy 与 Climate|Country|Modifier|Effect|Ideology|Trigger|Events
		# 同开关进入生产 ACTIVE；不得用 handoff / set_country_sync_store_writes_forbidden 冒充本路径。
		# Events 的授予只表示 worker 侧镜像 + 阶段位；legacy GameplayEventBus journal
		# 仍是生产消费源，消费者迁移是后续 PR。
		if not bool(host._country_worker_transport_capture.get("ok", false)) \
				and host._generator != null \
				and host._generator.has_method("capture_country_worker_inputs"):
			host._country_worker_transport_capture = \
				host._generator.capture_country_worker_inputs()
		if not bool(host._country_worker_transport_capture.get("ok", false)):
			if host._reject_web_daily_fallback("web_country_capture_failed",
					String(host._country_worker_transport_capture.get("code", "missing"))):
				return
			push_error(
				"[runtime-worker] Climate|Country|Trigger|Modifier|Effect|Ideology|Events|Economy ACTIVE refused: Country capture incomplete (%s)" % [
					String(host._country_worker_transport_capture.get("code", "missing"))])
			return
		# G8: best-effort Economy opinion publish before ACTIVE so Ideology
		# stage is not cold-started with a null opinion snapshot.
		if ext != null:
			var opinion_pub: Dictionary = ext.publish_ideology_worker_inputs()
			if not bool(opinion_pub.get("ok", false)):
				push_warning("[runtime-worker] Ideology opinion publish deferred: %s" % [
					String(opinion_pub.get("code", "unknown"))])
		config["simulation_thread_mode"] = "ACTIVE"
		config["graph_coverage_complete"] = true
		config["authoritative_domain_mask"] = host.runtime_authority_domain_mask
	# native_daily_inline：把"日屏障由谁执行"从 worker 线程换成调用线程。
	# 只有 ACTIVE 请求才谈得上内联日（SHADOW 的定义就是 worker 侧影子对拍）。
	# 显式写 false 而不是"不写"：同一个 key 若被遗留状态置真，host 会直接不
	# spawn 线程，而调用方还以为 worker 起了 —— 那是最难查的一种"起来了但没跑"。
	var want_inline = climate_authority_active and web_wants_inline
	config["native_daily_inline"] = want_inline
	var started: Dictionary = host._generator.start_runtime_worker(config)
	if not bool(started.get("ok", false)):
		host._web_worker_start_ok = false
		host._web_worker_start_code = String(started.get("code", "unknown"))
		if climate_authority_active:
			# 权威启动失败不能静默退回 SHADOW：主线程的 climate/country 抑制门读的是
			# worker 侧的授予位，授予没发生就不会抑制，于是主线程仍在算。
			# 但调用方以为已经转权威了，所以这里必须响。
			push_error("[runtime-worker] Climate|Country|Trigger|Modifier|Effect|Ideology|Events authority start refused: %s (%s)" % [
				String(started.get("code", "unknown")),
				String(started.get("message", ""))])
		else:
			push_warning("[runtime-worker] SHADOW start deferred: %s" % String(
				started.get("code", "unknown")))
		# web 上 worker 没起来，而内联又被互斥关掉 ⇒ 没有任何执行者。必须当场
		# 退回内联，否则日历停在 day 1（用户看到的"世界不动"）。
		# 判据用 `runtime_native_daily_inline`（用户是否允许内联），不要求
		# "worker 被要过" —— 起不来就是起不来，与谁请求的无关。
		if host._is_web_build() and host.runtime_native_daily_inline and not want_inline \
				and not host._web_worker_inline_fallback:
			print("[runtime-worker] web start failed (%s) -> falling back to native_daily_inline" \
				% host._web_worker_start_code)
			host._web_worker_inline_fallback = true
			host._start_production_shadow_worker()
			return
		host._reject_web_daily_fallback("web_native_start_failed", host._web_worker_start_code)
		return
	host._web_worker_start_ok = true
	# 回退路径下 start 成功说明"内联起来了"，不是"worker 起来了"，diag 必须分得清。
	host._web_worker_start_code = "inline_fallback" if host._web_worker_inline_fallback else "ok"
	host._native_daily_inline_active = bool(started.get("native_daily_inline", false))
	# 二次校验：请求了 worker 却反馈 inline=true，说明配置没生效。宁可回退内联，
	# 也不要留一个"看起来起了、其实日屏障还在主线程"的状态。
	if not host._native_daily_inline_active and bool(want_inline):
		host._web_worker_start_ok = false
		host._web_worker_start_code = "inline_flag_mismatch"
		if host._reject_web_daily_fallback("web_inline_flag_mismatch", "原生模块没有启用所请求的 inline 执行器"):
			return
		push_error("[runtime-worker] native_daily_inline requested but host reported false")
	# P1/P3：worker 真的起来了才谈得上预发布与领先量限流。内联日不适用
	# （它的消费者就是本线程，预发布只会让环卡住）。
	host._apply_web_worker_parallel_channels(climate_authority_active, started)
	if climate_authority_active:
		print("[runtime-worker] production ACTIVE started mask=",
			host.runtime_authority_domain_mask,
			" auto_pod=", host.runtime_economy_auto_pod_active,
			" inline=", host._native_daily_inline_active,
			" web_worker=", host._web_worker_requested(),
			" prefetch_days=", host._environment_prefetch_days_active,
			" max_lead_days=", host._max_worker_lead_days)
	host._sync_runtime_worker_clock()


## P1/P3 的开关落地。只有"worker 线程真的在跑"时才打开：
##   P1 预发布 K 天 + 把环境帧发布权收归 `_process` 预发布器（单一发布者）
##   P3 允许 worker 领先主线程 K 天
## 关掉时 K=0、发布权归还全部调用点、领先上限 0 ⇒ 回到改动前逐表达式的行为。

func _apply_web_worker_parallel_channels(host, climate_authority_active: bool,
		started: Dictionary) -> void:
	# 判据用 **请求模式**，不用 effective 模式：worker 刚启动时
	# `authoritative_domain_mask` 还是 0（授予要等第一天提交），
	# 用 effective 判会得到 OFF，预发布永远打不开。
	var worker_running = climate_authority_active \
		and not host._native_daily_inline_active \
		and String(started.get("requested_simulation_thread_mode", "OFF")) == "ACTIVE" \
		and String(started.get("state", "")) != "FAULTED"
	var prefetch_days = host._effective_environment_prefetch_days() if worker_running else 0
	# ── 能力门：**没有预发布所需 API 就绝不独占发布权** ──────────────────
	#
	# 这一条是 web 上"日历停在 day 1"的直接原因，必须写清楚：预发布器需要
	# `environment_ring_has_capacity()` / `runtime_committed_day()`（本轮新增）。
	# 如果 side module 是旧的一份（`Build-Web.cmd skip-native` 就会这样），这两个
	# 方法不存在 ⇒ `_service_worker_lead_and_prefetch()` 第一行就 return ⇒
	# **一帧都不会发**；而发布权已经被预发布器独占，S1/S2/S3 三个调用点全部
	# 被 suppressed ⇒ 环境帧为 0 ⇒ worker 无法推进 ⇒ `mode=OFF`、日历停住、
	# `fault_code` 为空（因为没有任何域报错，只是没输入）。
	#
	# 所以发布权必须与"能力"一起转移：能力不在，K 就归 0，继续由 S1/S2/S3 发。
	if prefetch_days > 0 and not host._environment_prefetch_capable():
		print("[runtime-worker] P1 prefetch disabled: DCWorldExt lacks " +
			"environment_ring_has_capacity/runtime_committed_day " +
			"(stale side module? rerun Build-Web.cmd with native rebuild) " +
			"-> environment frames stay on S1/S2/S3")
		prefetch_days = 0
	if OS.get_environment("PK_NO_ENV_PREFETCH") == "1":
		print("[runtime-worker] P1 prefetch disabled by PK_NO_ENV_PREFETCH=1 (A/B)")
		prefetch_days = 0
	if host._generator != null and host._generator.has_method("set_worker_environment_publisher"):
		# 预发布器独占发布权；否则归还给 S1/S2/S3 三个既有调用点。
		var callsite = MapGenerator.ENV_CALLSITE_PREFETCH if prefetch_days > 0 else 0
		host._generator.set_worker_environment_publisher(callsite)
	host._max_worker_lead_days = prefetch_days + host.WORKER_LEAD_MARGIN_DAYS if prefetch_days > 0 else 0
	host._environment_prefetch_days_active = prefetch_days
	host._release_prefetch_barrier_to_clock()
	if host._world_clock != null and host._world_clock.has_method("set_max_worker_lead_days"):
		host._world_clock.set_max_worker_lead_days(host._max_worker_lead_days)
		if host._world_clock.has_method("set_max_worker_lag_days"):
			host._world_clock.set_max_worker_lag_days(host._max_worker_lead_days)
	if prefetch_days > 0:
		print("[runtime-worker] P1 prefetch enabled days=", prefetch_days,
			" publisher=prefetch P3 lead_budget=", host._max_worker_lead_days,
			" (worker_running=", worker_running, ")")


## 把"当前生效的预发布天数 K"同步给时钟。
##
## 时钟要用它判断"预发布器是不是正因为领先额度用完而暂停" —— 那种时候日历是
## 唯一能解开闭环的一方，必须允许它推进（否则 预发布器等日历 / 日历等 worker /
## worker 等帧 三方互锁，浏览器实测 clk 恒 1、cd 4）。K=0 时这条通道完全关闭。

func _release_prefetch_barrier_to_clock(host) -> void:
	if host._world_clock == null or not host._world_clock.has_method("report_worker_prefetch_days"):
		return
	host._world_clock.report_worker_prefetch_days(host._environment_prefetch_days_active)


## 预发布器的**能力**判定：缺任何一个 C++ 探测方法就只能退回 S1/S2/S3 发布。
## `PK_NO_ENV_PREFETCH=1` 是 A/B 用的显式关闭（也让"旧 side module"这条
## 失效路径可以在 headless 上复现）。

func _environment_prefetch_capable(host) -> bool:
	if OS.get_environment("PK_NO_ENV_PREFETCH") == "1":
		return false
	if host._generator == null or not host._generator.has_method("get_data_core_world_ext"):
		return false
	var ext = host._generator.get_data_core_world_ext()
	return ext != null \
		and ext.has_method("environment_ring_has_capacity") \
		and ext.has_method("runtime_committed_day")


func _stop_previous_runtime_worker(host) -> Dictionary:
	return await preload("res://scripts/game/world_runtime_preparation.gd").stop_worker(
		host._generator, host._preparation_process_frame)


## G4 moved host responsibilities
func _defer_building_visual_catalog_after_ready(host) -> void:
	if host._exiting_tree or not host.is_inside_tree():
		return
	if host.PK_WEB_SKIP_DEFERRED_VISUAL_LAYERS:
		return
	var session = host._runtime_session
	var token: int = session.generation
	var timer = host.get_tree().create_timer(3.0, true, false, true)
	await timer.timeout
	if host._exiting_tree or not host.is_inside_tree() or not session.is_current(token):
		return
	var started = Time.get_ticks_msec()
	var report: Dictionary = host.refresh_building_visual_catalog()
	var elapsed = Time.get_ticks_msec() - started
	print("[building-visual] web deferred catalog ok=%s %dms" % [
		str(report.get("ok", false)), elapsed])
	WebTelemetry.emit("bind_step", {"s": "deferred_building_visual_done", "dur": elapsed})

func _adopt_generated_seed(host, generated_seed: int) -> void:
	if generated_seed <= 0 or host._new_game_config.is_empty():
		return
	var base = host._new_game_config.get("base", {})
	if not base is Dictionary:
		return
	var recorded = int((base as Dictionary).get("initial_seed", 0))
	if recorded == generated_seed:
		return
	(base as Dictionary)["initial_seed"] = generated_seed
	push_warning("[session] generated world seed %d adopted (session config requested %d); saves now reproduce this world" % [
		generated_seed, recorded])


# ─── 地图生成失败诊断（mapgen-diagnostics）───────────────────────────────
# generate_world 失败时把 MapGenerator.last_generation_error 整块留在 host 上，
# 由 player_game 交给 WorldLoadingOverlay 展示/复制/落盘。

func last_world_generation_error_text(host) -> String:
	if host.last_world_generation_error.is_empty():
		return ""
	var detail = String(host.last_world_generation_error.get("detail_text", ""))
	if not detail.is_empty():
		return detail
	# 兜底：没有 detail_text 时用 JSON，但必须先剔除原始 native report——
	# 它带 10+ 个 n_cells 级 PackedArray，直接 stringify 会产出几 MB 文本。
	var safe = host.last_world_generation_error.duplicate()
	safe.erase("native_report_raw")
	return JSON.stringify(safe, "  ", true)


## 生成失败归因：把 MapGenerator 的结构化错误压成"一句中文 + 阶段 + 原因 + 排查建议"。
## 传 preflight_override 时表示失败发生在 generate() 之前（自检拦下）。

func _report_world_generation_failure(host, preflight_override: Dictionary = {}) -> void:
	var err: Dictionary = {}
	if host._generator != null:
		# 浅拷贝：只复制顶层键，native_report_raw 仍指向同一份原始字典（不重复分配）。
		err = host._generator.last_generation_error.duplicate()
	if err.is_empty() and not preflight_override.is_empty():
		var first_issue = ""
		var issues: Array = preflight_override.get("issues", [])
		if not issues.is_empty() and issues[0] is Dictionary:
			first_issue = String((issues[0] as Dictionary).get("message", ""))
		err = {
			"stage": "preflight",
			"reason": "preflight_failed",
			"summary": "生成前自检未通过：%s" % first_issue,
			"hint": "按下面 preflight 里点名的缺失项处理；安卓一般是原生库缺失/过旧。",
			"preflight": preflight_override,
			"env": preflight_override.get("env", {}),
			"native_report": {},
			"superseded": false,
		}
	if err.is_empty():
		err = {
			"stage": "unknown",
			"reason": "map_generator_failed",
			"summary": "地图生成器返回空结果，且未留下任何诊断信息。",
			"hint": "这是 MapGenerator 之外的调用层问题；请附完整 logcat/godot.log。",
			"preflight": {},
			"env": {},
			"native_report": {},
			"superseded": false,
		}
	# 被新一轮 generate 取代：不弹失败面板，否则会盖住新一轮的进度条。
	if bool(err.get("superseded", false)):
		print("[mapgen] generation superseded at stage=%s (no failure UI)"
			% String(err.get("stage", "?")))
		return
	if host._generator != null:
		err["detail_text"] = host._generator.last_generation_error_text()
	host.last_world_generation_error = err
	var summary = host._world_generation_failure_summary(err)
	# 同一行同时 print + push_error：print 给 adb logcat，push_error 给编辑器/错误面板。
	print("[mapgen][fatal] %s" % summary)
	push_error("[mapgen][fatal] %s" % summary)
	host.world_generation_failed.emit(summary)


## 非 MapGenerator 来源的失败（开局初始化 / 存档恢复）：自建诊断记录后统一上报。
## 走同一条 print+push_error+signal 通道，保证 UI/日志/文件三处看到的是同一段文本。

func _emit_world_generation_failure(host, stage: String, reason: String, summary: String, hint: String) -> void:
	host.last_world_generation_error = {
		"stage": stage,
		"reason": reason,
		"summary": summary,
		"hint": hint,
		"preflight": {},
		"env": {},
		"native_report": {},
		"superseded": false,
		"detail_text": host._format_world_generation_detail(stage, reason, summary, hint),
	}
	var line = host._world_generation_failure_summary(host.last_world_generation_error)
	print("[mapgen][fatal] %s" % line)
	push_error("[mapgen][fatal] %s" % line)
	host.world_generation_failed.emit(line)


## 非 MapGenerator 来源失败的多行详情（结构与 MapGenerator 的保持同构，便于统一复制）。

func _format_world_generation_detail(host, stage: String, reason: String, summary: String, hint: String) -> String:
	var timestamp = Time.get_datetime_string_from_system(true)
	return host.HostValueHelpers._format_world_generation_detail(
		stage, reason, summary, hint, timestamp)


## 一句话摘要：含 stage + reason + 一句排查建议（玩家能看懂、开发者能定位）。

func _world_generation_failure_summary(host, err: Dictionary) -> String:
	return host.HostValueHelpers._world_generation_failure_summary(err)


## --mapgen-selfcheck：把自检 JSON 打到 stdout（安卓：adb logcat -s godot:*）。
## 桌面/headless 走 tests/world/mapgen_selfcheck.tscn；这里覆盖"已经进了游戏场景"的场景。

func _maybe_run_mapgen_selfcheck_cli(host) -> void:
	if not MapGenerator.mapgen_selfcheck_requested():
		return
	var probe = MapGenerator.new()
	var report: Dictionary = probe.run_mapgen_selfcheck(true)
	print("[mapgen][selfcheck][summary] ok=%s" % str(report.get("ok", false)))


func generate_world(host, seed_override: int = -1, safe_area: Rect2 = Rect2()) -> void:
	host._generation_request += 1
	var request = host._generation_request
	var clock_was_paused = host._world_clock.paused if host._world_clock != null else true
	var closed: Dictionary = await host.close_world()
	if request != host._generation_request or host._exiting_tree or not host.is_inside_tree():
		return
	if not bool(closed.get("ok", false)):
		host._emit_world_generation_failure("close", String(closed.get("code", "close_failed")),
			"上一局游戏尚未关闭。", "请保留运行日志。")
		return
	host._runtime_session = host.WorldSession.new()
	host._session_frames = host.SessionFrameGate.new()
	host._session_prepare_options = {"seed": seed_override, "safe_area": safe_area,
		"clock_was_paused": clock_was_paused}
	host.last_world_generation_error.clear()
	host._clear_web_daily_fallback_failure()
	var configured: Dictionary = host._runtime_session.configure(host.WorldSessionModules.entries(host, host._session_extensions))
	if not bool(configured.get("ok", false)):
		host._emit_world_generation_failure("modules", String(configured.get("code", "module_invalid")),
			"游戏系统配置不完整。", String(configured.get("detail", "")))
		return
	var prepared: Dictionary = await host._runtime_session.prepare()
	if not bool(prepared.get("ok", false)):
		if prepared.get("code") != "session_cancelled" and not host._exiting_tree:
			if host.last_world_generation_error.is_empty():
				host._emit_world_generation_failure("modules", String(prepared.get("code", "module_prepare_failed")),
					"游戏系统准备失败。", String(prepared.get("message", "")))
			await host.close_world()
		return
	host._runtime_ready_for_ticks = true
	# The host process also drains building visual dirty cells. Keep it alive for
	# the normal runtime; overlay refreshes must not disable construction/era
	# intelligence updates.
	host.set_process(true)
	if host._world_clock != null:
		# 只在输入及 worker 均已建立后恢复新世界/存档原有的运行模式。
		host._world_clock.pause(bool(host._session_prepare_options.clock_was_paused))
		host.on_clock_running_changed(not host._world_clock.paused)
	# Web 构建：世界就绪事件（agent 侧据此判断"可以点开始了"）。
	WebTelemetry.emit("ready", {
		"day": host._world_clock.day_index() if host._world_clock != null else -1,
		"paused": host._world_clock.paused if host._world_clock != null else true,
	})
	host.world_ready.emit(host._current_map, host._world_data, host._generator, host._view_adapter)


func _session_noop(host) -> void:
	pass


func _session_ok(host) -> Dictionary:
	return {"ok": true}


## native_daily_inline 是否要在本次会话生效。
##
## 浏览器里默认生效（没有可用 worker 线程）。桌面/headless 只有显式
## PK_NATIVE_DAILY_INLINE=1 才生效 —— 桌面 worker 路径不受影响。
## PROBE：置 false 可让 web 退回主线程 daily tick（用来二分"首日挂死"是否在内联路径）。

func _apply_feature_flags(host) -> void:
	DCFeatureFlags.set_cell_indirection(host.cell_indirection_enabled)
	DCFeatureFlags.set_ocean_current_visual(host.ocean_current_visual_enabled)
	DCFeatureFlags.set_sea_ice_atlas(host.sea_ice_atlas_enabled)
	# 桌面默认开；移动端由 mobile_terrain_horizon_enabled 开关控制；Web 只有
	# Compatibility/WebGL2 后端，逐像素 marching 开销和离屏 viewport 读回都偏重
	# （readback 在部分浏览器/驱动上会强制同步 flush GPU 管线），默认关闭——
	# 这里必须和 DCFeatureFlags.terrain_horizon_gpu_bake_active() 的 fallback
	# 语义保持一致。之前只判断了 "mobile"，漏判 Web，导致每次开局都把这条显式
	# meta 覆盖成 true，盖掉了 feature_flags.gd 里"web 默认关"的设计。
	var terrain_horizon_enabled: bool
	if OS.has_feature("mobile"):
		terrain_horizon_enabled = host.mobile_terrain_horizon_enabled
	elif DCFeatureFlags.is_web():
		terrain_horizon_enabled = false
	else:
		terrain_horizon_enabled = true
	DCFeatureFlags.set_terrain_horizon_gpu_bake(terrain_horizon_enabled)


func _world_setup_config(host) -> Dictionary:
	if not host._new_game_config.is_empty():
		return host._new_game_config
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
	if base is Dictionary:
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
		host.mobile_terrain_horizon_enabled = bool((render as Dictionary).get(
			"mobile_terrain_horizon_enabled", host.mobile_terrain_horizon_enabled
		))


func _cmdline_pkmap_path(host) -> String:
	for raw in OS.get_cmdline_user_args():
		var item = str(raw)
		if item.begins_with("pkmap="):
			return item.substr(6).strip_edges()
	return ""


func _apply_pkmap_override(host, cfg: MapConfig) -> void:
	if cfg == null:
		return
	var path = ""
	var setup = host._world_setup_config()
	var base = setup.get("base", {})
	if base is Dictionary:
		path = String((base as Dictionary).get("pkmap_path", "")).strip_edges()
	var cmdline = host._cmdline_pkmap_path()
	if not cmdline.is_empty():
		# `pkmap=` 是开新局的开发入口。读档时地图来源必须以存档 config 为准：
		# 用命令行换一张图会让重建世界与存档世界不一致（起始格/领土/地形互相
		# 矛盾），最终在视野收尾被判为失败。这里直接忽略并留一条 warning。
		if not host._pending_load_bundle.is_empty():
			push_warning("[pkmap] ignoring pkmap= cmdline override during load (saved source: %s)" % path)
		else:
			path = cmdline
	if path.is_empty():
		return
	cfg.map_source = "pkmap"
	cfg.pkmap_path = path
	var peeked: Dictionary = host.PkmapIOScript.peek_pkmap(path)
	if not bool(peeked.get("ok", false)):
		push_error("[pkmap] 无法预读 %s：%s" % [path, String(peeked.get("message", ""))])
		return
	cfg.width = int(peeked.get("width", cfg.width))
	cfg.height = int(peeked.get("height", cfg.height))
	cfg.sea_level = float(peeked.get("sea_level", cfg.sea_level))
	var packed_seed = int(peeked.get("seed", 0))
	if packed_seed != 0:
		cfg.seed = packed_seed
	host.map_width = cfg.width
	host.map_height = cfg.height
	host.sea_level = cfg.sea_level


func _load_runtime_climate_profile(host) -> ClimateProfile:
	var profile = ResourceLoader.load(host.DEFAULT_CLIMATE_PROFILE_PATH, "Resource") as ClimateProfile
	if profile != null:
		profile = profile.duplicate(true) as ClimateProfile
	else:
		push_warning("[PlayerGame] default ClimateProfile missing; using in-memory defaults.")
		profile = ClimateProfile.new()
	profile.set_meta(&"source_path", host.DEFAULT_CLIMATE_PROFILE_PATH)
	return profile


func _apply_runtime_climate_profile(host, generator_ref: MapGenerator) -> void:
	if generator_ref == null:
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
				if not profile_props.has(key):
					continue
				profile.set(key, (climate as Dictionary)[name])
				climate_overrides[key] = true
	if OS.has_feature("mobile"):
		host._apply_mobile_profile_defaults(profile, climate_overrides)
	generator_ref.climate_profile = profile


func _apply_mobile_profile_defaults(host, profile: ClimateProfile, climate_overrides: Dictionary) -> void:
	if profile.get("native_daily_sim_stride") != null and not climate_overrides.has("native_daily_sim_stride"):
		profile.native_daily_sim_stride = host.MOBILE_NATIVE_DAILY_STRIDE_DAYS
	if profile.get("native_daily_commit_lag_budget_days") != null and not climate_overrides.has("native_daily_commit_lag_budget_days"):
		profile.native_daily_commit_lag_budget_days = host.MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS
	if profile.get("native_daily_sea_ice_spread_dt_cap_days") != null and not climate_overrides.has("native_daily_sea_ice_spread_dt_cap_days"):
		profile.native_daily_sea_ice_spread_dt_cap_days = float(host.MOBILE_NATIVE_DAILY_STRIDE_DAYS)
	if profile.get("natural_resource_daily_stride") != null and not climate_overrides.has("natural_resource_daily_stride"):
		profile.natural_resource_daily_stride = maxi(int(profile.natural_resource_daily_stride), host.MOBILE_NATURAL_RESOURCE_STRIDE_DAYS)
	if profile.get("dynamic_visual_atlas_upload_stride") != null and not climate_overrides.has("dynamic_visual_atlas_upload_stride"):
		profile.dynamic_visual_atlas_upload_stride = maxi(int(profile.dynamic_visual_atlas_upload_stride), host.MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE)
	if profile.get("weather_field_advect_steps") != null and not climate_overrides.has("weather_field_advect_steps"):
		profile.weather_field_advect_steps = mini(int(profile.weather_field_advect_steps), host.MOBILE_WEATHER_FIELD_ADVECT_STEPS)


func _init_tod_profile(host) -> void:
	if host._tod_profile != null:
		return
	host._tod_profile = TODProfile.new()
	host._tod_profile.configure(0.65, 0.55, 0.72, 1.0)


func _on_baker_stage_progress(host, stage: String, fraction: float) -> void:
	host.generation_progress.emit(stage, fraction)


func _enter_tree(host) -> void:
	host._exiting_tree = false
	host.add_to_group(&"world_sessions")


func _exit_tree(host) -> void:
	host._clock_binding.detach()
	host._exiting_tree = true
	host._runtime_session.request_close()
	host._session_frames.cancel()
	if host._generator != null:
		host._generator.cancel_loading_work()
		host._generator.request_runtime_stop()


func _loading_visual_step(host, label: String) -> void:
	# 这条日志行打印的是"上一步"的耗时；进度同理：每次调用时把上一步标记为完成，
	# 把生成后阶段的游标向前推一格。label 本身只进日志，UI 文案用固定 stage key。
	host._advance_visual_progress("bind")
	var now=Time.get_ticks_usec()
	if host._loading_visual_usec>0:
		var step_ms = float(now-host._loading_visual_usec)/1000.0
		print("[loading-visual-substep] %s %.1fms" % [host._loading_visual_name, step_ms])
		WebTelemetry.emit("visual_step", {"label": host._loading_visual_name, "dur": step_ms})
	host._loading_visual_usec=now
	host._loading_visual_name=label


# ─── 生成后阶段进度（绑渲染器 → 植被图层 → 建筑外观）─────────────────────────
# 生成器返回后到 hide_completed() 之间没有任何 bake_progress，原先只有一次
# "upload"=98% 就静默到 100%。这里用与生成器同款的单调几何游标：
# 每推进一步向 VISUAL_PROGRESS_CEIL 逼近固定比例，严格单调、永不回退、
# 也永远到不了 1.0（100% 只属于 WorldLoadingOverlay.hide_completed()）。
# fraction 语义是"UI 完成度绝对值"，overlay 的 ABSOLUTE_STAGES 直接照搬。

func _advance_visual_progress(host, stage: String, begin: bool = false) -> void:
	if host._visual_progress <= 0.0:
		# 0.0 = 本次生成还没进入后期阶段（或已复位）：不打扰 overlay 的现有进度。
		# 只有 generate_world 里"生成器已返回"那一次调用带 begin=true。
		if not begin:
			return
		host._visual_progress = host.VISUAL_PROGRESS_START
	else:
		host._visual_progress = minf(host.VISUAL_PROGRESS_CEIL,
			host._visual_progress + (host.VISUAL_PROGRESS_CEIL - host._visual_progress) * host.VISUAL_PROGRESS_GAIN)
	host.generation_progress.emit(stage, host._visual_progress)


## HexRenderer 建完一个植被层回调一次（_rebuild_cooperative →
## _setup_loading_vegetation_layers_for_deferred_fill 的逐层循环）。
## 有些画质档位会构建 14+ 层，逐层推进才不会在 98% 处长时间停住。

func _on_renderer_loading_layer_progress(host, _layer_index: int, _layer_count: int,
		_layer_name: String) -> void:
	host._advance_visual_progress("visual")


func annual_report_status(host) -> Dictionary:
	return host._annual_reports.status()


func annual_report_snapshot(host, report_id: int) -> Dictionary:
	return host._annual_reports.snapshot(report_id)


func annual_report_history(host, offset: int = 0, limit: int = 64) -> Dictionary:
	return host._annual_reports.history(offset, limit)


func mark_annual_report_presented(host, report_id: int) -> void:
	host._annual_reports.mark_presented(report_id)


func annual_reports_waiting_for_year(host, year: int) -> bool:
	return host._annual_reports.waiting_for_year(year)


func annual_report_catalogs(host) -> Dictionary:
	if host._generator == null:
		return {}
	var economy = host._generator.get_economy_facade()
	var country: Dictionary = host._generator.get_country_facade().native_catalog()
	var professions = PackedStringArray()
	for id in economy.profession_ids():
		professions.append(economy.profession_display_name(StringName(id)))
	var buildings = PackedStringArray()
	for index in economy.building_type_ids().size():
		buildings.append(economy.building_display_name(index))
	var goods = PackedStringArray()
	for index in economy.good_ids().size():
		goods.append(economy.good_display_name(index))
	# 资源名与「认没认出来」走同一个循环、同一个下标：报表里的 resource id 就是
	# ResourceProfileRegistry.ordered() 的下标，两个数组必须等长同序。
	var viewer: Dictionary = host._player_completed_technology_ids()
	var know_discovery: bool = bool(viewer.get("ok", false))
	var known: PackedStringArray = viewer.get("ids", PackedStringArray())
	var resources = PackedStringArray()
	var discovered = PackedByteArray()
	for profile in ResourceProfileRegistry.ordered():
		resources.append(String(profile.display_name))
		if know_discovery:
			discovered.append(1 if ResourceProfileRegistry.discovery_visible(profile, known) else 0)
	var out: Dictionary = {"profession_names": professions, "building_names": buildings,
		"resource_names": resources, "good_names": goods,
		"technology_names": country.get("technology_display_names", PackedStringArray())}
	# 拿不到玩家科技快照时**不带这个键**：调用方"没报告"与"查了是 0"是两件事，
	# 缺省必须表现为"不过滤"，否则一次读档期的查询失败会把整栏资源吞掉。
	if know_discovery:
		out["resource_discovered"] = discovered
	return out


## 玩家已完成科技 id。年报"资源"栏要据此藏掉还没认出来的矿种。
## 认矿门控（ResourceProfile.discovery_technology_tags）本来就在 GDScript 侧，
## 原生只管"能不能采"，所以这条过滤只能在这里做 —— 与地图覆盖层、悬停卡同一套判定。

func _player_completed_technology_ids(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("get_country_facade"):
		return {"ok": false}
	var facade = host._generator.get_country_facade()
	if facade == null or not facade.has_method("snapshot"):
		return {"ok": false}
	if host._player_country_handle == 0:
		host._player_country_handle = host._resolve_player_country_handle()
	if host._player_country_handle == 0:
		return {"ok": false}
	var snapshot: Dictionary = facade.snapshot(host._player_country_handle)
	if not bool(snapshot.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "ids": snapshot.get("technology_ids", PackedStringArray())}
