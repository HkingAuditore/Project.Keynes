extends RefCounted

## Formats the daily simulation breakdown; receives the existing generator read interface.

static func _print_daily_breakdown(_generator, tick_no: int, sus_ms: float, render_ms: float,
		ui_ms: float, total_ms: float, skipped_day: bool, is_warn: bool) -> void:
	var prefix: String = "[fast tick WARN]" if is_warn else "[fast tick]"
	print("%s #%d sus=%.2f render=%.2f ui=%.2f total=%.0fms skip_day=%s"
		% [prefix, tick_no, sus_ms, render_ms, ui_ms, total_ms, str(skipped_day)])
	if _generator == null or not _generator.has_method("sus_report_last_tick"):
		return
	if _generator.has_method("sus_report_last_tick_summary"):
		var summary: Dictionary = _generator.sus_report_last_tick_summary()
		if not summary.is_empty():
			print("    sus_window p95=%.2fms max=%.2fms over1ms=%d largest=%s/%s/%s path=%s %.2fms cursor=%d-%d" % [
				float(summary.get("sus_sim_p95_300", 0.0)),
				float(summary.get("sus_sim_max_300", 0.0)),
				int(summary.get("over_1ms_count_300", 0)),
				str(summary.get("largest_slice_job", "")),
				str(summary.get("largest_slice_stage", "")),
				str(summary.get("largest_slice_substage", "")),
				str(summary.get("largest_slice_path", "")),
				float(summary.get("largest_slice_ms", 0.0)),
				int(summary.get("largest_slice_cursor_start", -1)),
				int(summary.get("largest_slice_cursor_end", -1)),
			])
	var report: Dictionary = _generator.sus_report_last_tick()
	if report.is_empty():
		print("    (sus report empty)")
		return
	for job_id in report.keys():
		var r: Dictionary = report[job_id]
		var elapsed_ms: float = float(r.get("elapsed_ms", 0.0))
		var slices: int = int(r.get("slices_run", 0))
		var skipped: String = str(r.get("skipped_reason", ""))
		if skipped != "":
			print("    %s skipped(%s)" % [str(job_id), skipped])
		else:
			print("    %s ran=%.2fms slices=%d progress=%.2f"
				% [str(job_id), elapsed_ms, slices, float(r.get("progress_ratio", 0.0))])
			if job_id == &"natural_resource_daily":
				var nr: Dictionary = r
				if not nr.has("kernel_ms") and not nr.has("native_ms") and _generator != null \
						and _generator.has_method("natural_resource_last_result"):
					var nr_last: Dictionary = _generator.natural_resource_last_result()
					if not nr_last.is_empty():
						nr = nr_last
				var nr_kernel_ms: float = float(nr.get("kernel_ms", nr.get("native_ms", 0.0)))
				var nr_wall_ms: float = float(nr.get("wrapper_wall_ms", elapsed_ms))
				var nr_wrapper_ms: float = float(nr.get("wrapper_overhead_ms", max(0.0, nr_wall_ms - nr_kernel_ms)))
				print("        natural_resource path=%s wall=%.2f cpp=%.3f compute=%.3f loop=%.3f flush=%.3f wrapper=%.3f layout=%s dispatches=%d resources=%d/%d skipped_static=%d published_to_slot=%s total_delta=%.5f" % [
					str(nr.get("path", r.get("path", ""))),
					nr_wall_ms,
					nr_kernel_ms,
					float(nr.get("kernel_compute_ms", nr.get("compute_ms", 0.0))),
					float(nr.get("kernel_loop_ms", nr.get("loop_ms", 0.0))),
					float(nr.get("kernel_flush_ms", nr.get("flush_ms", 0.0))),
					nr_wrapper_ms,
					str(nr.get("kernel_loop_layout", nr.get("loop_layout", ""))),
					int(nr.get("kernel_loop_dispatches", nr.get("loop_dispatches", 0))),
					int(nr.get("published_resource_count", nr.get("resource_count", 0))),
					int(nr.get("input_resource_count", nr.get("resource_count", 0))),
					int(nr.get("skipped_static_resources", 0)),
					str(nr.get("published_to_slot", false)),
					float(nr.get("total_delta", 0.0)),
				])
			# Daily-sim perf instrumentation：refresh_climate_daily 内部 6 段拆解
			# （Pass A / Pass B / ocean / sea_ice / ice_bake / transp）
			if job_id == &"refresh_climate_daily" and _generator != null \
					and _generator.has_method("sus_climate_breakdown"):
				var b: Dictionary = _generator.sus_climate_breakdown()
				if not b.is_empty():
					print("        A=%.1f B=%.1f ocean=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f cells=%d pass=%s partial=%s dirty=%.2f visited=%.2f path=%s" % [
						float(b.get("pass_a_ms", 0.0)),
						float(b.get("pass_b_ms", 0.0)),
						float(b.get("ocean_ms", 0.0)),
						float(b.get("sea_ice_ms", 0.0)),
						float(b.get("ice_bake_ms", 0.0)),
						float(b.get("transp_ms", 0.0)),
						int(b.get("cells", 0)),
						str(b.get("current_pass", "")),
						str(b.get("partial", false)),
						float(b.get("dirty_ratio", 1.0)),
						float(b.get("visited_ratio", 1.0)),
						str(b.get("pass_b_path", "full")),
					])
					# DataCore: climate sub-pass 取数路径标识（B-1）
					# dots-flag-prune-pr1 (2026-05-22)： use_data_core_climate flag 已删除。
					# Climate 现恒走 DataCore 单路径：
					#   data_core             — World 已 bind + 25 个 comp_id 全部缓存
					#   data_core_cells_only  — World 已 bind，但 comp_id 还未缓存好
					#   legacy                — World 还没绑定（启动早期 fallback）
					var _dcc_path: String = "legacy"
					var _dcc_w = _generator.get_data_core_world() if _generator.has_method("get_data_core_world") else null
					if _dcc_w != null and _dcc_w.is_bound():
						var _cjob = _generator._refresh_climate_daily_job if "_refresh_climate_daily_job" in _generator else null
						if _cjob != null and _cjob.has_method("data_core_ready") and _cjob.data_core_ready():
							_dcc_path = "data_core"
						else:
							_dcc_path = "data_core_cells_only"
					# I1.A-1: 与 weather "path=..." 对齐，便于 grep / A-B 桶聚合（保留旧 dc=
					# 字段一并打印以兼容历史 ab_test*.log 解析脚本）
					print("        climate path=%s dc=%s" % [_dcc_path, _dcc_path])
					if is_warn:
						print("        climate wrapper breakdown round_start_total_ms=%.3f round_start_terrain_sync_ms=%.3f capture_start_state_ms=%.3f round_start_mark_stale_ms=%.3f round_start_soa_begin_ms=%.3f round_start_dirty_ms=%.3f pass_overhead_ms=%.3f finalize_total_ms=%.3f finalize_finalizer_ms=%.3f finalize_breakdown_ms=%.3f finalize_soak_ms=%.3f finalize_finish_pass_ms=%.3f finalize_reset_transp_ms=%.3f finalize_flush_dirty_ms=%.3f finalize_mark_stale_ms=%.3f finalize_dump_stats_ms=%.3f finalizer_total_ms=%.3f finalizer_cell_ms=%.3f finalizer_temp_ms=%.3f finalizer_tta_ms=%.3f finalizer_thermal_ms=%.3f finalizer_sort_ms=%.3f finalizer_write_dense_ms=%.3f tta_mirror=%s/%d tta_clamped=%d thermal_init=%d temp_mirror=%s" % [
							float(b.get("round_start_total_ms", 0.0)),
							float(b.get("round_start_terrain_sync_ms", 0.0)),
							float(b.get("capture_start_state_ms", 0.0)),
							float(b.get("round_start_mark_stale_ms", 0.0)),
							float(b.get("round_start_soa_begin_ms", 0.0)),
							float(b.get("round_start_dirty_ms", 0.0)),
							float(b.get("pass_overhead_ms", 0.0)),
							float(b.get("finalize_total_ms", 0.0)),
							float(b.get("finalize_finalizer_ms", 0.0)),
							float(b.get("finalize_breakdown_ms", 0.0)),
							float(b.get("finalize_soak_ms", 0.0)),
							float(b.get("finalize_finish_pass_ms", 0.0)),
							float(b.get("finalize_reset_transp_ms", 0.0)),
							float(b.get("finalize_flush_dirty_ms", 0.0)),
							float(b.get("finalize_mark_stale_ms", 0.0)),
							float(b.get("finalize_dump_stats_ms", 0.0)),
							float(b.get("finalizer_total_ms", 0.0)),
							float(b.get("finalizer_cell_ms", 0.0)),
							float(b.get("finalizer_temp_ms", 0.0)),
							float(b.get("finalizer_tta_ms", 0.0)),
							float(b.get("finalizer_thermal_ms", 0.0)),
							float(b.get("finalizer_sort_ms", 0.0)),
							float(b.get("finalizer_write_dense_ms", 0.0)),
							str(b.get("finalizer_tta_cell_mirror", false)),
							int(b.get("finalizer_tta_cell_mirror_count", 0)),
							int(b.get("finalizer_tta_clamped_count", 0)),
							int(b.get("finalizer_thermal_init_count", 0)),
							str(b.get("finalizer_temperature_cell_mirror", false)),
						])
					var _pass_diag: Dictionary = b.get("pass_diag", {})
					var _transp_diag: Dictionary = {}
					var _transp_diag_source: String = ""
					var _pass_stage: String = str(_pass_diag.get("stage_name", _pass_diag.get("stage", "")))
					if _pass_stage == "transp" and str(_pass_diag.get("path", "")) == "gdext":
						_transp_diag = _pass_diag
						_transp_diag_source = "current"
					else:
						var _cached_transp_diag: Dictionary = b.get("transp_native_diag", {})
						var _cached_tick: int = int(_cached_transp_diag.get("_tick_idx", -1))
						var _breakdown_tick: int = int(b.get("_tick_idx", -2))
						if str(_cached_transp_diag.get("path", "")) == "gdext" \
								and (_cached_tick == _breakdown_tick or _breakdown_tick < 0):
							_transp_diag = _cached_transp_diag
							_transp_diag_source = "cached"
					if is_warn and not _transp_diag.is_empty():
						print("        transp/native breakdown source=%s diagnostic_wall_ms=%.2f refresh_ms=%.3f native_call_ms=%.3f native_ms=%.3f native_compute_ms=%.3f native_apply_ms=%.3f native_flush_ms=%.3f sync_total_ms=%.3f sync_write_ms=%.3f sync_mark_ms=%.3f dirty_count=%d sync_path=%s" % [
							_transp_diag_source,
							float(_transp_diag.get("diagnostic_wall_ms", _transp_diag.get("elapsed_ms", 0.0))),
							float(_transp_diag.get("refresh_ms", 0.0)),
							float(_transp_diag.get("native_call_ms", 0.0)),
							float(_transp_diag.get("native_ms", 0.0)),
							float(_transp_diag.get("native_compute_ms", 0.0)),
							float(_transp_diag.get("native_apply_ms", 0.0)),
							float(_transp_diag.get("native_flush_ms", 0.0)),
							float(_transp_diag.get("sync_total_ms", _transp_diag.get("sync_ms", 0.0))),
							float(_transp_diag.get("sync_write_ms", 0.0)),
							float(_transp_diag.get("sync_mark_ms", 0.0)),
							int(_transp_diag.get("dirty_count", 0)),
							str(_transp_diag.get("sync_path", "")),
						])
					# Ocean pass C++ vs fallback diag：当本片是 ocean_water / ocean_land
					# 时附带 gdext runs / fallbacks / last rc，定位"为何 fallback"
					var _cur_pass: String = str(b.get("current_pass", ""))
					if _cur_pass == "ocean_land" or _cur_pass == "ocean_water":
						var _ocp_runs: int = -1
						var _ocp_fb: int = -1
						var _ocp_total_ms: float = -1.0
						var _ocp_flag: bool = false
						var _ocp_field_runs: String = ""
						var _ocp_field_fb: String = ""
						var _ocp_field_total: String = ""
						if _cur_pass == "ocean_land":
							_ocp_field_runs = "_gdext_ocean_land_runs"
							_ocp_field_fb = "_gdext_ocean_land_fallbacks"
							_ocp_field_total = "_gdext_ocean_land_total_ms"
						else:
							_ocp_field_runs = "_gdext_ocean_water_runs"
							_ocp_field_fb = "_gdext_ocean_water_fallbacks"
							_ocp_field_total = "_gdext_ocean_water_total_ms"
						if _ocp_field_runs in _generator:
							_ocp_runs = int(_generator.get(_ocp_field_runs))
						if _ocp_field_fb in _generator:
							_ocp_fb = int(_generator.get(_ocp_field_fb))
						if _ocp_field_total in _generator:
							_ocp_total_ms = float(_generator.get(_ocp_field_total))
						# dots-flag-prune-pr1: use_gdext_ocean_water/land flags were removed;
						# these passes are now constant-on when ext+method probes succeed.
						_ocp_flag = true
						var _ocp_avg: float = (_ocp_total_ms / float(_ocp_runs)) if _ocp_runs > 0 else 0.0
						print("        %s gdext flag=%s runs=%d fallbacks=%d avg_native=%.2fms" % [
							_cur_pass, str(_ocp_flag), _ocp_runs, _ocp_fb, _ocp_avg,
						])
					if str(b.get("current_pass", "")) == "sea_ice" and "_last_sea_ice_daily_breakdown" in _generator:
						var sid: Dictionary = _generator._last_sea_ice_daily_breakdown
						if not sid.is_empty():
							print("        sea_ice_daily path=%s pack=%.1f refresh=%.1f native=%.3f native_wall=%.1f sync=%.1f flip=%.1f total=%.1f water=%d flipped=%d" % [
								str(sid.get("path", "")),
								float(sid.get("pack_ms", 0.0)),
								float(sid.get("refresh_ms", 0.0)),
								float(sid.get("native_ms", -1.0)),
								float(sid.get("native_wall_ms", 0.0)),
								float(sid.get("sync_ms", 0.0)),
								float(sid.get("flip_ms", 0.0)),
								float(sid.get("total_wall_ms", 0.0)),
								int(sid.get("water", 0)),
								int(sid.get("flipped", 0)),
							])
			# Daily-sim perf instrumentation：weather_refresh 内部细分
			# （weather_tick 包括 advance/spawn/distribute/cyclone 四段；
			#  之后是 transp/albedo/veg_dyn/cover_rebake/veg_rebake/feedback）
			if job_id == &"weather_refresh" and _generator != null \
					and _generator.has_method("sus_weather_breakdown"):
				var wb: Dictionary = _generator.sus_weather_breakdown()
				if not wb.is_empty():
					print("        weather_tick=%.1f (adv=%.1f spawn=%.1f dist=%.1f cyc=%.1f) field_bake=%.1f transp=%.1f albedo=%.1f veg_dyn=%.1f rebake_cv=%.1f rebake_vg=%.1f feedback=%.1f fronts=%d" % [
						float(wb.get("weather_tick_ms", 0.0)),
						float(wb.get("advance_ms", 0.0)),
						float(wb.get("spawn_ms", 0.0)),
						float(wb.get("distribute_ms", 0.0)),
						float(wb.get("cyclone_ms", 0.0)),
						float(wb.get("weather_field_bake_ms", 0.0)),
						float(wb.get("transp_ms", 0.0)),
						float(wb.get("albedo_ms", 0.0)),
						float(wb.get("veg_dyn_ms", 0.0)),
						float(wb.get("cover_rebake_ms", 0.0)),
						float(wb.get("veg_rebake_ms", 0.0)),
						float(wb.get("feedback_ms", 0.0)),
						int(wb.get("fronts", 0)),
					])
					if wb.has("job_total_ms"):
						print("        weather_job total=%.1f prelude=%.1f begin=%.1f run_slice=%.1f direct_a=%.1f commit=%.1f stage_b=%.1f sync=%.1f soak=%.1f unattributed=%.1f" % [
							float(wb.get("job_total_ms", 0.0)),
							float(wb.get("prelude_ms", 0.0)),
							float(wb.get("begin_stage_a_ms", 0.0)),
							float(wb.get("run_stage_a_slice_ms", 0.0)),
							float(wb.get("stage_a_direct_ms", 0.0)),
							float(wb.get("commit_stage_a_ms", 0.0)),
							float(wb.get("stage_b_outer_ms", 0.0)),
							float(wb.get("sync_fronts_ms", 0.0)),
							float(wb.get("soak_dump_ms", 0.0)),
							float(wb.get("job_unattributed_ms", 0.0)),
						])
					if wb.has("field_commit_total_ms"):
						print("        weather_commit inner=%.1f setup=%.1f loop=%.1f dc=%.1f conv=%.1f dist=%.1f summary=%.1f path=%s" % [
							float(wb.get("field_commit_total_ms", 0.0)),
							float(wb.get("field_commit_setup_ms", 0.0)),
							float(wb.get("field_commit_loop_ms", 0.0)),
							float(wb.get("field_commit_dc_ms", 0.0)),
							float(wb.get("field_commit_convergence_ms", 0.0)),
							float(wb.get("distribute_ms", 0.0)),
							float(wb.get("field_summary_ms", 0.0)),
							str(wb.get("field_commit_path", "")),
						])
					# DataCore: 末尾 path 标记，方便 A/B 对照（plan 任务 10）
					# dots-flag-prune-pr1 (2026-05-22)： use_data_core_weather flag 已删除。
					# Weather 现恒走 DataCore 单路径 ; path 仔细仅反映 World bind + comp_id
					# 缓存状态。
					var _dc_path: String = "legacy"
					var _dc_w = _generator.get_data_core_world() if _generator.has_method("get_data_core_world") else null
					if _dc_w != null and _dc_w.is_bound():
						_dc_path = "data_core_cells_only"
					print("        weather path=%s" % _dc_path)
					# dots-flag-prune-pr1 (2026-05-22)：--validate-weather 机制已废弃。
			if job_id == &"enum_atlas_upload" and _generator != null \
					and _generator.has_method("sus_enum_atlas_breakdown"):
				var eb: Dictionary = _generator.sus_enum_atlas_breakdown()
				if not eb.is_empty():
					print("        enum_atlas_upload axis=%s path=%s elapsed=%.2f patch=%.2f img=%.2f upload=%.2f dirty=%dpx/%dcells cache=%s pending_cv=%s pending_vg=%s" % [
						str(eb.get("axis", "")),
						str(eb.get("path", "unknown")),
						float(eb.get("elapsed_ms", 0.0)),
						float(eb.get("buffer_patch_ms", 0.0)),
						float(eb.get("image_ms", 0.0)),
						float(eb.get("upload_ms", 0.0)),
						int(eb.get("dirty_pixels", 0)),
						int(eb.get("dirty_cells", 0)),
						str(eb.get("cache_valid", false)),
						str(eb.get("cover_pending", false)),
						str(eb.get("vegetation_pending", false)),
					])
			if job_id == &"season_refresh" and _generator != null \
					and _generator.has_method("sus_season_refresh_breakdown"):
				var sb: Dictionary = _generator.sus_season_refresh_breakdown()
				if not sb.is_empty():
					print("        season_refresh stages=%s" % [str(sb)])
			# Daily wind 归因：ocean_currents 每 wind_period_ticks 跑一次 C++ daily
			# wind prepass（SLP + wind 两段权威）。把 slp/wind 分段耗时 + 主导段直接
			# 打到调度日志，配合 sus_window largest=ocean_currents/daily_wind_prepass/
			# <daily_wind_slp|daily_wind_wind> 定位是哪一段吃预算。仅在本 tick 真正跑
			# 了 daily wind（daily_wind_due=true）时打印，避免每 tick 复读旧值。
			if job_id == &"ocean_currents" and _generator != null \
					and _generator.has_method("sus_ocean_currents_breakdown"):
				var ob: Dictionary = _generator.sus_ocean_currents_breakdown()
				if not ob.is_empty() and bool(ob.get("daily_wind_due", false)):
					print("        daily_wind stage=%s path=%s slp=%.2f wind=%.2f total=%.2f refresh=%.2f dominant=%s/%.2f slp_dp95=%.5f wind_dp95=%.5f commit=%s reason=%s" % [
						str(ob.get("daily_wind_stage_requested", "both")),
						str(ob.get("daily_wind_path", "")),
						float(ob.get("daily_wind_slp_ms", -1.0)),
						float(ob.get("daily_wind_wind_ms", -1.0)),
						float(ob.get("daily_wind_elapsed_ms", -1.0)),
						float(ob.get("daily_wind_refresh_ms", -1.0)),
						str(ob.get("daily_wind_dominant_stage", "")),
						float(ob.get("daily_wind_dominant_stage_ms", 0.0)),
						float(ob.get("daily_wind_slp_delta_p95", 0.0)),
						float(ob.get("daily_wind_delta_p95", 0.0)),
						str(ob.get("daily_wind_commit_ok", false)),
						str(ob.get("daily_wind_fallback_reason", "")),
					])
					# SLP 内部分段埋点（C++ run_slp_field_pass 返回；旧 DLL 缺失=-1）。
					# 仅在本 tick 真跑了 SLP（passA 有值）时打印，定位 3ms 花在哪。
					if float(ob.get("daily_wind_slp_passA_ms", -1.0)) >= 0.0:
						print("        daily_wind/slp_internal passA=%.3f passB=%.3f norm=%.3f marshall=%.3f (passA=逐cell三角/insolation, passB=邻域平滑, norm=recenter+p95排序+缩放, marshall=prev混合+发布)" % [
							float(ob.get("daily_wind_slp_passA_ms", -1.0)),
							float(ob.get("daily_wind_slp_passB_ms", -1.0)),
							float(ob.get("daily_wind_slp_norm_ms", -1.0)),
							float(ob.get("daily_wind_slp_marshall_ms", -1.0)),
						])
			if job_id == &"native_daily_sim":
				var nd: Dictionary = r.get("native_daily_report", {})
				if nd.is_empty() and _generator != null \
						and _generator.has_method("native_daily_last_result"):
					nd = _generator.native_daily_last_result()
				if not nd.is_empty():
					var nd_breakdown: Dictionary = nd.get("breakdown", {})
					var nd_pass_keys = nd.get("bundle_pass_keys", [])
					print("        native_daily sample=%d commit=%d age=%d/%d over=%s state=%s wall=%.2f bundle=%.2f native_call=%.2f cpp_total=%.2f apply=%.2f compute=%.2f refresh=%.2f flush=%.2f weather=%.2f passes=%d" % [
						int(nd.get("native_daily_sample_day", nd_breakdown.get("native_daily_sample_day", -1))),
						int(nd.get("native_daily_commit_day", nd_breakdown.get("native_daily_commit_day", -1))),
						int(nd.get("native_daily_age_days", nd_breakdown.get("native_daily_age_days", 0))),
						int(nd.get("native_daily_commit_lag_budget_days", nd_breakdown.get("native_daily_commit_lag_budget_days", 0))),
						str(nd.get("native_daily_commit_over_budget", nd_breakdown.get("native_daily_commit_over_budget", false))),
						str(nd.get("native_daily_contract_state", nd_breakdown.get("native_daily_contract_state", ""))),
						float(nd.get("wrapper_wall_ms", elapsed_ms)),
						float(nd.get("bundle_ms", 0.0)),
						float(nd.get("native_call_ms", nd.get("native_ms", 0.0))),
						float(nd.get("native_ms", nd.get("total_ms", 0.0))),
						float(nd.get("apply_ms", 0.0)),
						float(nd.get("compute_ms", 0.0)),
						float(nd.get("refresh_ms", 0.0)),
						float(nd.get("flush_ms", 0.0)),
						float(nd_breakdown.get("weather_ms", 0.0)),
						int(nd_pass_keys.size()),
					])
					var nd_finalizer_total: float = float(nd.get("finalizer_total_ms", nd_breakdown.get("finalizer_total_ms", 0.0)))
					if is_warn and (nd_finalizer_total > 0.0 or bool(nd.get("thermal_finalizer_applied", nd_breakdown.get("thermal_finalizer_applied", false)))):
						print("        native_daily/finalizer path=%s total=%.3f cell=%.3f temp=%.3f tta=%.3f thermal=%.3f sort=%.3f sea_ice=%.3f precip=%.3f write_mode=%s dense=%.3f sparse=%.3f dirty_collect=%.3f dirty_skip=%s skip_comps=%s comps_dense=%s comps_sparse=%s dirty_ratio=%.3f dirty=%d/%d/%d cells=%d temp_clamped=%d tta_clamped=%d thermal_init=%d temp_mirror=%s tta_mirror=%s/%d max_dt=%.5f pre_max_dt=%.5f" % [
							str(nd.get("finalizer_path", nd_breakdown.get("finalizer_path", ""))),
							nd_finalizer_total,
							float(nd.get("finalizer_cell_ms", nd_breakdown.get("finalizer_cell_ms", 0.0))),
							float(nd.get("finalizer_temp_ms", nd_breakdown.get("finalizer_temp_ms", 0.0))),
							float(nd.get("finalizer_tta_ms", nd_breakdown.get("finalizer_tta_ms", 0.0))),
							float(nd.get("finalizer_thermal_ms", nd_breakdown.get("finalizer_thermal_ms", 0.0))),
							float(nd.get("finalizer_sort_ms", nd_breakdown.get("finalizer_sort_ms", 0.0))),
							float(nd.get("finalizer_sea_ice_ms", nd_breakdown.get("finalizer_sea_ice_ms", 0.0))),
							float(nd.get("finalizer_precip_ms", nd_breakdown.get("finalizer_precip_ms", 0.0))),
							str(nd.get("finalizer_write_mode", nd_breakdown.get("finalizer_write_mode", ""))),
							float(nd.get("finalizer_write_dense_ms", nd_breakdown.get("finalizer_write_dense_ms", 0.0))),
							float(nd.get("finalizer_sparse_write_ms", nd_breakdown.get("finalizer_sparse_write_ms", 0.0))),
							float(nd.get("finalizer_dirty_collect_ms", nd_breakdown.get("finalizer_dirty_collect_ms", 0.0))),
							str(nd.get("finalizer_dirty_collect_skipped", nd_breakdown.get("finalizer_dirty_collect_skipped", false))),
							str(nd.get("finalizer_dirty_collect_skip_components", nd_breakdown.get("finalizer_dirty_collect_skip_components", []))),
							str(nd.get("finalizer_dense_components", nd_breakdown.get("finalizer_dense_components", []))),
							str(nd.get("finalizer_sparse_components", nd_breakdown.get("finalizer_sparse_components", []))),
							float(nd.get("finalizer_dirty_ratio", nd_breakdown.get("finalizer_dirty_ratio", 0.0))),
							int(nd.get("finalizer_dirty_count_temp", nd_breakdown.get("finalizer_dirty_count_temp", 0))),
							int(nd.get("finalizer_dirty_count_tta", nd_breakdown.get("finalizer_dirty_count_tta", 0))),
							int(nd.get("finalizer_dirty_count_thermal", nd_breakdown.get("finalizer_dirty_count_thermal", 0))),
							int(nd.get("finalizer_cells_seen", nd_breakdown.get("finalizer_cells_seen", 0))),
							int(nd.get("temp_delta_clamped_count", nd_breakdown.get("temp_delta_clamped_count", 0))),
							int(nd.get("finalizer_tta_clamped_count", nd_breakdown.get("finalizer_tta_clamped_count", 0))),
							int(nd.get("finalizer_thermal_init_count", nd_breakdown.get("finalizer_thermal_init_count", 0))),
							str(nd.get("finalizer_temperature_cell_mirror", nd_breakdown.get("finalizer_temperature_cell_mirror", false))),
							str(nd.get("finalizer_tta_cell_mirror", nd_breakdown.get("finalizer_tta_cell_mirror", false))),
							int(nd.get("finalizer_tta_cell_mirror_count", nd_breakdown.get("finalizer_tta_cell_mirror_count", 0))),
							float(nd.get("max_temp_delta", nd_breakdown.get("max_temp_delta", 0.0))),
							float(nd.get("preclamp_max_temp_delta", nd_breakdown.get("preclamp_max_temp_delta", 0.0))),
						])
