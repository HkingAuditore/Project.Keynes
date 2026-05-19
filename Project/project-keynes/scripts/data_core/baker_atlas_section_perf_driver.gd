## scripts/data_core/baker_atlas_section_perf_driver.gd
##
## plan/dirty-push-atlas-encode 阶段 G —— 4 档 baker atlas section perf 采集器。
##
## 背景：
##   阶段 D / E / F 已落地 dirty_push + C++ atlas encode；阶段 G 验收要在
##   "同一存档 / 同一玩法负载"下顺序切 4 档 flag 各跑 N tick，把 baker chunk
##   段 ms 灌入 DCDotsFinalPushPerfVerdict.evaluate_baker_atlas_section，
##   产出 markdown AB 报告。
##
## 4 档：
##   - legacy       : dirty_push=false  cpp=false   force_full=false （旧路径）
##   - mask_gd      : dirty_push=true   cpp=false   force_full=false （GD-mask 增量）
##   - mask_gd_full : dirty_push=true   cpp=false   force_full=true  （GD-mask 但每帧
##                                                                     全图 dirty —— 防回归
##                                                                     最坏工况）
##   - mask_cpp     : dirty_push=true   cpp=true    force_full=false （C++ encode）
##
## 单档采样：一次 tick 包裹"4 个 baker.rebake_*_only"调 Time.get_ticks_usec()。
## 这模拟 dynamic_visual_atlas_upload_system 单 tick 跑完 4 phase 的总开销，
## 与 system 内部 stride/budget 切片不完全 1:1，但对 4 档相对差的体现足够。
##
## 不动点：
##   - 不修改 baker / verdict / world_ext / climate_profile 任何生产路径
##   - 跑完自动恢复 flag 原值（哪怕中途 push_error 也走 finally 段恢复）
##   - 写文件用 FileAccess.WRITE + 异常守护，写不出不影响游戏
##
## 调用方式（dev-only，由调试 HUD / debug_console 触发）：
##   var driver = DCBakerAtlasSectionPerfDriver.new()
##   var report_path: String = driver.run(climate_profile, baker, map, world, 200)
##   # report_path 即写出的 markdown 路径，可在 debug HUD 直接 click open。

class_name DCBakerAtlasSectionPerfDriver extends RefCounted

const DCDotsFinalPushPerfVerdictScript := preload("res://scripts/data_core/dots_final_push_perf_verdict.gd")

# ── 4 档定义：(label, dirty_push_enabled, cpp_atlas_encode_enabled, force_full_dirty) ─
const PHASES: Array = [
	["legacy",       false, false, false],
	["mask_gd",      true,  false, false],
	["mask_gd_full", true,  false, true ],
	["mask_cpp",     true,  true,  false],
]

# 报告写入根目录（运行时存在则用，不存在则尝试 mkdir）
const REPORT_DIR: String = "res://.codebuddy/perf-reports"

# ── 公开入口 ─────────────────────────────────────────────────────────────────

## 跑完 4 档 × ticks_per_phase tick，写出 markdown，返回报告路径（写失败返回空串）。
##
## 入参：
##   climate_profile: ClimateProfile（必须含 dirty_push_enabled / cpp_atlas_encode_enabled）
##   baker: MapBaker
##   map: MapData
##   world: WorldData
##   ticks_per_phase: 单档采样 tick 数（默认 200）
##
## 返回：String —— 报告 markdown 绝对/res:// 路径；失败时返回 ""。
func run(climate_profile, baker, map, world, ticks_per_phase: int = 200) -> String:
	if climate_profile == null or baker == null or map == null or world == null:
		push_error("[plan/dirty-push-atlas-encode/G] perf driver: any of climate_profile / baker / map / world is null")
		return ""

	var orig_dirty_push: Variant = climate_profile.get("dirty_push_enabled")
	var orig_cpp_encode: Variant = climate_profile.get("cpp_atlas_encode_enabled")

	var section_samples: Dictionary = {}
	var phase_meta: Array = []  # 每档运行时的元信息（实际 tick 数 / 失败原因）

	# 跑每档；任一档异常都不中断，记录元信息后继续。
	for phase_def in PHASES:
		var label: String = String(phase_def[0])
		var dirty_push: bool = bool(phase_def[1])
		var cpp_encode: bool = bool(phase_def[2])
		var force_full: bool = bool(phase_def[3])
		print_rich("[plan/dirty-push-atlas-encode/G] perf driver phase=%s dirty_push=%s cpp=%s force_full=%s ticks=%d"
				% [label, str(dirty_push), str(cpp_encode), str(force_full), ticks_per_phase])
		# 切 flag
		climate_profile.set("dirty_push_enabled", dirty_push)
		climate_profile.set("cpp_atlas_encode_enabled", cpp_encode)
		# 重置 baker 部分 cache，让该档起点公平（cache_invalid 首帧 + 之后 N-1 帧 valid）。
		# 仅清 sig 字典，不清 buffer —— 这样 chunk_begin 仍判 cache_valid（因 cache_size
		# 还在），但 sig 比对不再命中，强制每个 cell 都进入"写 byte"分支。
		_reset_baker_sig_cache_only(baker)
		# 采集 ms
		var samples: Array = _collect_baker_section_ms(baker, map, world, ticks_per_phase, force_full)
		section_samples[label] = samples
		phase_meta.append({
			"label": label,
			"requested_ticks": ticks_per_phase,
			"actual_samples": samples.size(),
		})

	# 恢复 flag（无论 verdict / write 是否成功）
	climate_profile.set("dirty_push_enabled", orig_dirty_push)
	climate_profile.set("cpp_atlas_encode_enabled", orig_cpp_encode)

	# 调 verdict + 出 markdown
	var verdict: Dictionary = DCDotsFinalPushPerfVerdictScript.evaluate_baker_atlas_section(section_samples)
	# 顺便打 print_rich 行（验收时控制台肉眼可见）
	var lines: Array = DCDotsFinalPushPerfVerdictScript.format_baker_atlas_section_lines(verdict)
	for line in lines:
		print_rich(line)

	var env: Dictionary = _collect_env_meta(map, world, ticks_per_phase)
	var report_path: String = _write_markdown_report(verdict, env, phase_meta, section_samples)
	return report_path


# ── 单档采样：跑 ticks 次"完整 4 atlas rebake"，每次包裹 Time.get_ticks_usec() ─────

func _collect_baker_section_ms(baker, map, world, ticks: int, force_full_dirty: bool) -> Array:
	var samples: Array = []
	samples.resize(ticks)
	var n_cells: int = map.cell_count() if map.has_method("cell_count") else 0
	var change_cursor: int = 0
	for t in range(ticks):
		# 喂"动态 dirty"：每 tick 改 ~5% cell 的 temperature/moisture/snow_cover，
		# 让 sig cache 不会全命中也不会全失效。这是 baker 段的真实日常工况。
		# force_full_dirty=true 时改 100% cell（mask_gd_full 最坏工况）。
		if n_cells > 0:
			var change_count: int = n_cells if force_full_dirty else maxi(1, n_cells / 20)
			for _i in range(change_count):
				var idx: int = (change_cursor + _i) % n_cells
				_perturb_cell(map, idx, t)
			change_cursor = (change_cursor + change_count) % n_cells

		var t0_us: int = Time.get_ticks_usec()
		baker.rebake_dynamic_cell_atlas_only(map, world)
		baker.rebake_ecology_visual_atlas_only(map, world)
		baker.rebake_dyn_atlas_smooth(map, world)
		baker.rebake_ice_state_atlas(map, world)
		var elapsed_ms: float = float(Time.get_ticks_usec() - t0_us) / 1000.0
		samples[t] = elapsed_ms
	return samples


# 只清 sig 字典，不清 buffer / cache_size —— 让 chunk_begin 走 cache_valid=true
# 路径，强制每 cell sig 比对失败重写（模拟"日常变化但尺寸未变"的稳定工况）。
func _reset_baker_sig_cache_only(baker) -> void:
	if "_last_dynamic_cell_sigs" in baker:
		baker._last_dynamic_cell_sigs.clear()
	if "_last_ecology_visual_sigs" in baker:
		baker._last_ecology_visual_sigs.clear()
	if "_last_dyn_smooth_cell_sigs" in baker:
		baker._last_dyn_smooth_cell_sigs.clear()
	if "_last_ice_state_cell_bytes" in baker:
		baker._last_ice_state_cell_bytes.clear()


# 改一个 cell 的 temperature/moisture/snow_cover/vegetation_vitality 字段 + 同步
# 到 MapData.*_arr（DCWorldExt SoA snapshot 共享 *_arr，cpp 路径会立刻看到新值）。
func _perturb_cell(map, idx: int, tick_seed: int) -> void:
	var cell = map.cell_at(idx)
	if cell == null:
		return
	# 让扰动是确定性的（同一 idx + 同一 tick_seed → 同一变化），便于 4 档对比有可重复性
	var phase: float = float((idx * 37 + tick_seed * 11) % 32) / 32.0  # 0..1
	var delta: float = 0.05 * sin(phase * TAU)
	var new_temp: float = clampf(float(cell.temperature) + delta, 0.0, 1.0)
	var new_moist: float = clampf(float(cell.moisture) + 0.5 * delta, 0.0, 1.0)
	cell.temperature = new_temp
	cell.moisture = new_moist
	# 同步 *_arr（必要：cpp 路径走 SoA，不再回读 cell.*）
	if "temp_arr" in map and idx < map.temp_arr.size():
		map.temp_arr[idx] = new_temp
	if "moisture_arr" in map and idx < map.moisture_arr.size():
		map.moisture_arr[idx] = new_moist


# ── 元信息收集（写入报告头部） ──────────────────────────────────────────────

func _collect_env_meta(map, world, ticks_per_phase: int) -> Dictionary:
	var cell_count_val: int = map.cell_count() if map.has_method("cell_count") else 0
	var px_size: Vector2i = world.derived_size if "derived_size" in world else Vector2i.ZERO
	var n_pix: int = px_size.x * px_size.y
	return {
		"cell_count": cell_count_val,
		"derived_size": "%dx%d" % [px_size.x, px_size.y],
		"n_pix": n_pix,
		"soak_ticks_per_phase": ticks_per_phase,
		"total_ticks": ticks_per_phase * PHASES.size(),
		"godot_version": Engine.get_version_info().get("string", ""),
		"os_name": OS.get_name(),
		"timestamp": Time.get_datetime_string_from_system(),
	}


# ── markdown 报告写入 ───────────────────────────────────────────────────────

func _write_markdown_report(verdict: Dictionary, env: Dictionary, phase_meta: Array, section_samples: Dictionary) -> String:
	# 确保目录存在
	var dir_abs: String = ProjectSettings.globalize_path(REPORT_DIR)
	if not DirAccess.dir_exists_absolute(dir_abs):
		var rc: int = DirAccess.make_dir_recursive_absolute(dir_abs)
		if rc != OK:
			push_warning("[plan/dirty-push-atlas-encode/G] perf driver: cannot mkdir %s rc=%d (skip write)" % [dir_abs, rc])
			return ""

	var ts_compact: String = Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "-")
	var fname: String = "dirty-push-atlas-encode_AB_%s.md" % ts_compact
	var path_res: String = "%s/%s" % [REPORT_DIR, fname]
	var path_abs: String = ProjectSettings.globalize_path(path_res)

	var f: FileAccess = FileAccess.open(path_res, FileAccess.WRITE)
	if f == null:
		push_warning("[plan/dirty-push-atlas-encode/G] perf driver: cannot open %s err=%d (skip write)"
				% [path_abs, FileAccess.get_open_error()])
		return ""

	f.store_line("# plan/dirty-push-atlas-encode 阶段 G —— 4 档 baker atlas section AB 报告")
	f.store_line("")
	f.store_line("- timestamp: %s" % String(env.get("timestamp", "")))
	f.store_line("- godot: %s" % String(env.get("godot_version", "")))
	f.store_line("- os: %s" % String(env.get("os_name", "")))
	f.store_line("- cell_count: %d" % int(env.get("cell_count", 0)))
	f.store_line("- derived_size: %s (n_pix=%d)" % [String(env.get("derived_size", "")), int(env.get("n_pix", 0))])
	f.store_line("- soak: %d tick/phase × %d phase = %d tick"
			% [int(env.get("soak_ticks_per_phase", 0)), PHASES.size(), int(env.get("total_ticks", 0))])
	f.store_line("")
	f.store_line("## 验收门槛（DCDotsFinalPushPerfVerdict）")
	f.store_line("")
	f.store_line("- mask_gd p95 ≤ legacy × 0.5（必须减半）")
	f.store_line("- mask_cpp p95 ≤ mask_gd × 0.5（必须再减半）")
	f.store_line("- 任一档不得比 legacy 慢 10% 以上（mask_gd_full 最坏工况防回归）")
	f.store_line("")
	f.store_line("## verdict 总结")
	f.store_line("")
	var overall: bool = bool(verdict.get("overall", false))
	f.store_line("- **overall**: %s" % ("PASS" if overall else "FAIL"))
	f.store_line("- legacy_p95: %.3f ms" % float(verdict.get("legacy_p95", 0.0)))
	var reductions: Dictionary = verdict.get("reductions", {})
	for k in reductions.keys():
		f.store_line("- reduction(%s) = %.1f%% of legacy" % [String(k), float(reductions[k]) * 100.0])
	var fail_reasons: Array = verdict.get("fail_reasons", [])
	if not fail_reasons.is_empty():
		f.store_line("")
		f.store_line("### fail reasons")
		for r in fail_reasons:
			f.store_line("- %s" % String(r))
	f.store_line("")
	f.store_line("## 4 档 stats")
	f.store_line("")
	f.store_line("| label | n | avg ms | p50 ms | p95 ms | p99 ms |")
	f.store_line("|---|---|---|---|---|---|")
	var by_label: Dictionary = verdict.get("by_label", {})
	for label in ["legacy", "mask_gd", "mask_gd_full", "mask_cpp"]:
		if not by_label.has(label):
			f.store_line("| %s | (no data) | | | | |" % label)
			continue
		var s: Dictionary = by_label[label]
		f.store_line("| %s | %d | %.3f | %.3f | %.3f | %.3f |"
				% [label, int(s.get("n", 0)),
				   float(s.get("avg", 0.0)), float(s.get("p50", 0.0)),
				   float(s.get("p95", 0.0)), float(s.get("p99", 0.0))])
	f.store_line("")
	f.store_line("## 原始 samples（前 32 tick × 4 档）")
	f.store_line("")
	f.store_line("| tick | legacy | mask_gd | mask_gd_full | mask_cpp |")
	f.store_line("|---|---|---|---|---|")
	var preview_n: int = 32
	for t in range(preview_n):
		var row: String = "| %d |" % t
		for label2 in ["legacy", "mask_gd", "mask_gd_full", "mask_cpp"]:
			var arr: Array = section_samples.get(label2, [])
			if t < arr.size():
				row += " %.3f |" % float(arr[t])
			else:
				row += " - |"
		f.store_line(row)
	f.store_line("")
	f.store_line("## phase meta")
	f.store_line("")
	for pm in phase_meta:
		f.store_line("- %s: requested_ticks=%d, actual_samples=%d"
				% [String(pm.get("label", "")), int(pm.get("requested_ticks", 0)), int(pm.get("actual_samples", 0))])
	f.store_line("")
	f.store_line("---")
	f.store_line("生成器：scripts/data_core/baker_atlas_section_perf_driver.gd")
	f.close()

	print_rich("[plan/dirty-push-atlas-encode/G] perf report written: %s" % path_abs)
	return path_res
