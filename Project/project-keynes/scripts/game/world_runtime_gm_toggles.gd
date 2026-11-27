extends RefCounted

## Reads and applies the toggles offered by the diagnostic GM panel.

static func get_gm_toggle_state(host, toggle_id: String) -> Dictionary:
	if host._world_clock == null and toggle_id == "simulation.paused":
		return host._gm_error("clock_unavailable", "时钟尚未就绪。")
	match toggle_id:
		"simulation.paused":
			return {"ok": true, "enabled": host._world_clock.paused}
		"ui.suppress_popups":
			return {"ok": true, "enabled": bool(host.player_confirmation_view().get("suppress_event_popups", false))}
		"ui.hide_all_except_gm":
			return {"ok": true, "enabled": bool(host.player_confirmation_view().get("hide_popups", false))}
		"simulation.click_claim_territory":
			return {"ok": true, "enabled": host._gm_click_claim_territory_enabled}
		"system.autosave":
			var save_service = host._game_save_service()
			if save_service == null:
				return host._gm_error("save_service_unavailable", "存档服务尚未就绪。")
			return {"ok": true, "enabled": bool(save_service.call("is_autosave_enabled"))}
		"visual.day_night":
			return {"ok": true, "enabled": host.day_night_enabled}
		"visual.fog_of_war":
			return {"ok": true, "enabled": host.is_fog_of_war_enabled()}
		"visual.water_effect":
			return host._gm_renderer_toggle_state("water_effect_enabled")
		"visual.ocean_current":
			return host._gm_renderer_toggle_state("ocean_current_enabled")
		"visual.extreme_weather":
			return host._gm_renderer_toggle_state("extreme_weather_ground_effect_enabled")
		"diagnostics.dynamic_visual_atlas_upload":
			return {"ok": true, "enabled": not bool(Engine.get_meta(&"force_disable_dva_upload", false))}
		"diagnostics.atlas_river_probe":
			var probe_baker = host._gm_map_baker()
			if probe_baker == null or not probe_baker.has_method("get_river_atlas_probe_state"):
				return host._gm_error("baker_unavailable", "MapBaker 尚未就绪。")
			var probe_state: Dictionary = probe_baker.get_river_atlas_probe_state()
			probe_state["ok"] = true
			return probe_state
		"diagnostics.perf_sampler":
			return host._gm_renderer_toggle_state("perf_sampler_enabled")
		"diagnostics.pk_log":
			return {"ok": true, "enabled": PKLog.enabled}
		"diagnostics.terrain_material_gate":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 7}
		"diagnostics.cell_index_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 1}
		"diagnostics.enum_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 8}
		"diagnostics.water_branch_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 13}
		"diagnostics.pre_adjust_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 11}
		"diagnostics.base_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 12}
		"diagnostics.river_flow_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 14}
		"diagnostics.static_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 15}
		"diagnostics.flow_texsize_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 16}
		"diagnostics.flow_texel_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 17}
		"diagnostics.cell_field_dom_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 18}
		"diagnostics.cell_field_weights_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 19}
		"diagnostics.cell_field_gap_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 20}
		"diagnostics.cell_field_warp_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 21}
		"diagnostics.cell_field_dom_encode_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 22}
		"diagnostics.cell_field_band_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 23}
		"diagnostics.dyn_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 9}
		"diagnostics.eco_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.terrain_surface_debug_view == 10}
		"diagnostics.sky_visibility_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": host._renderer.gi_debug_view == 1}
		"diagnostics.gi_off":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			return {"ok": true, "enabled": not host._gi_saved_strengths.is_empty()}
		"diagnostics.terrain_materials":
			return host._gm_renderer_toggle_state("terrain_materials_enabled")
	return host._gm_error("unknown_toggle", "未知 GM 开关。")



static func set_gm_toggle(host, toggle_id: String, enabled: bool) -> Dictionary:
	match toggle_id:
		"ui.suppress_popups", "ui.hide_all_except_gm":
			var action := "event_popup_policy" if toggle_id == "ui.suppress_popups" else "popup_policy"
			var receipt: Dictionary = host.submit_player_confirmation(action, int(enabled))
			if not bool(receipt.get("ok", false)):
				return host._gm_error(String(receipt.get("code", "")), "弹窗设置未受理。")
			return host._gm_ok("弹窗设置已排队。", true, int(receipt.effective_day))
		"simulation.paused":
			if host._world_clock == null:
				return host._gm_error("clock_unavailable", "时钟尚未就绪。")
			if host._runtime_worker_fault_paused and not enabled:
				return host._gm_error("runtime_faulted",
					"运行时已故障（%s），禁止继续推进日历。" % String(
						host._runtime_last_fault_diagnostics.get("fault_code", "faulted")))
			host._world_clock.pause(enabled)
			host.on_clock_running_changed(not enabled)
		"simulation.click_claim_territory":
			return host._gm_set_click_claim_territory_enabled(enabled)
		"system.autosave":
			var save_service = host._game_save_service()
			if save_service == null:
				return host._gm_error("save_service_unavailable", "存档服务尚未就绪。")
			var autosave_result: Dictionary = save_service.call("set_autosave_enabled", enabled)
			if not bool(autosave_result.get("ok", false)):
				return host._gm_error(String(autosave_result.get("code", "autosave_toggle_failed")),
					String(autosave_result.get("message", "自动存档开关保存失败。")))
		"visual.day_night":
			host.set_day_night_enabled(enabled)
		"visual.fog_of_war":
			return host.set_fog_of_war_enabled(enabled)
		"visual.water_effect":
			if not host._gm_call_renderer_toggle("set_water_effect_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.ocean_current":
			if not host._gm_call_renderer_toggle("set_ocean_current_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.extreme_weather":
			if not host._gm_call_renderer_toggle("set_extreme_weather_ground_effect_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.dynamic_visual_atlas_upload":
			Engine.set_meta(&"force_disable_dva_upload", not enabled)
		"diagnostics.atlas_river_probe":
			var probe_baker = host._gm_map_baker()
			if probe_baker == null or not probe_baker.has_method("set_river_atlas_probe_enabled"):
				return host._gm_error("baker_unavailable", "MapBaker 尚未就绪。")
			var probe_state: Dictionary = probe_baker.set_river_atlas_probe_enabled(enabled, host._current_map)
			probe_state["ok"] = true
			host.gm_toggle_changed.emit(toggle_id, bool(probe_state.get("enabled", enabled)))
			return probe_state
		"diagnostics.perf_sampler":
			if not host._gm_call_renderer_toggle("set_perf_sampler_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.pk_log":
			PKLog.enabled = enabled
		"diagnostics.terrain_material_gate":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 7 if enabled else 0
			host._print_terrain_material_gate_state()
		"diagnostics.cell_index_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 1 if enabled else 0
			if enabled:
				host._print_cell_index_view_state()
		"diagnostics.enum_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 8 if enabled else 0
			if enabled:
				host._print_enum_lut_view_state()
		"diagnostics.water_branch_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 13 if enabled else 0
			if enabled:
				print("[water-branch-view] 绿=陆地管线 / 白=B_SEA_ICE（cid<0 会无条件赋成它）"
					+ " / 蓝=B_OCEAN / 青=COAST / 深蓝=LAKE / 品红=REEF / 黄=KELP")
		"diagnostics.pre_adjust_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 11 if enabled else 0
		"diagnostics.base_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 12 if enabled else 0
		"diagnostics.river_flow_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 14 if enabled else 0
			if enabled:
				host._print_river_flow_state()
		"diagnostics.static_color_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 15 if enabled else 0
		"diagnostics.flow_texsize_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 16 if enabled else 0
			if enabled:
				print("[flow-texsize-view] 12 位二进制条：上半屏=宽 下半屏=高，左起最高位，"
					+ "白=1 深蓝=0，每 4 位一条红分隔")
				host._print_terrain_sampler_inventory()
		"diagnostics.flow_texel_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 17 if enabled else 0
			if enabled:
				print("[flow-texel-view] texelFetch 整数取样，绕过 filter_linear 与 wrap uv；"
					+ "恢复出细红河线 = 问题在过滤/采样状态而非纹理内容")
		"diagnostics.cell_field_dom_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 18 if enabled else 0
			if enabled:
				print("[cell-field-view] 18 = dom 一致性：红 = 解析格归属与烘焙 map_index 不同"
					+ "（应只出现在格界 1 纹素带内）；需要 terrain_cell_field_enabled = true")
		"diagnostics.cell_field_weights_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 19 if enabled else 0
			if enabled:
				print("[cell-field-view] 19 = 三格权重 RGB（对偶三角内应连续无硬边）；"
					+ "需要 terrain_cell_field_enabled = true")
		"diagnostics.cell_field_gap_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 20 if enabled else 0
			if enabled:
				print("[cell-field-view] 20 = gap 差值：红 = 解析 gap 与 edge_distance.R 超出容差；"
					+ "需要 terrain_cell_field_enabled = true")
		"diagnostics.cell_field_warp_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 21 if enabled else 0
			if enabled:
				print("[cell-field-view] 21 = 扭曲场可视化（rg → 屏幕向量）；"
					+ "需要 terrain_cell_field_enabled = true")
		"diagnostics.cell_field_dom_encode_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 22 if enabled else 0
			if enabled:
				print("[cell-field-view] 22 = dom offset 编码（R,G=col 低/高字节 B=row，A=1）；"
					+ "给 tests/world/cell_field_gpu_parity_probe.gd 回读比对用；"
					+ "需要 terrain_cell_field_enabled = true")
		"diagnostics.cell_field_band_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 23 if enabled else 0
			if enabled:
				print("[cell-field-view] 23 = 实际带宽 band 灰阶（band/0.86）；"
					+ "经线接缝整列变白 = fwidth 取在已回绕坐标上；"
					+ "需要 terrain_cell_field_enabled = true")
		"diagnostics.dyn_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 9 if enabled else 0
			if enabled:
				host._print_daily_lut_upload_state("dyn")
		"diagnostics.eco_lut_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.terrain_surface_debug_view = 10 if enabled else 0
			if enabled:
				host._print_daily_lut_upload_state("eco")
		"diagnostics.sky_visibility_view":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._renderer.gi_debug_view = 1 if enabled else 0
			if enabled:
				host._print_terrain_gi_state("sky-visibility-view")
		"diagnostics.gi_off":
			if host._renderer == null:
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
			host._set_terrain_gi_disabled(enabled)
		"diagnostics.terrain_materials":
			if not host._gm_call_renderer_toggle("set_terrain_materials_enabled", enabled):
				return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
		_:
			return host._gm_error("unknown_toggle", "未知 GM 开关。")
	var actual_enabled = bool(host.get_gm_toggle_state(toggle_id).get("enabled", enabled))
	host.gm_toggle_changed.emit(toggle_id, actual_enabled)
	return {"ok": true, "enabled": actual_enabled}
