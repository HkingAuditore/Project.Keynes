extends RefCounted


static func _advance_one_sim_day(owner: Variant) -> void:
	if owner.day_cost_probe_on:
		owner.day_cost_flush()
		owner._dcp_day = owner._last_day + 1
		owner._dcp_dispatch_usec = Time.get_ticks_usec()
	owner._last_day += 1
	if owner._max_worker_lag_days > 0:
		owner._worker_lag_days += 1
	owner.day_changed.emit(owner._last_day)
	if owner.day_cost_probe_on:
		owner.day_cost_add(&"clk", owner._dcp_elapsed_ms(owner._dcp_dispatch_usec))
	var day_season: int = owner.season_index_for_day(owner._last_day)
	if day_season != owner._last_season:
		owner._last_season = day_season
		owner.season_changed.emit(day_season)
	var day_year: int = owner.year_index_for_day(owner._last_day)
	if day_year != owner._last_year:
		owner._last_year = day_year
		owner._apply_year_rollover(day_year)


static func publish_runtime_date(owner: Variant, committed: int) -> void:
	if not owner._runtime_calendar_admit.is_valid() or committed + 1 <= owner._last_day:
		return
	owner._last_day = committed + 1
	owner.current_day = float(owner._last_day) + owner._runtime_calendar_fraction
	owner._runtime_calendar_through = maxi(owner._runtime_calendar_through, committed)
	owner._publishing_runtime_date = true
	owner.day_changed.emit(owner._last_day)
	var season: int = owner.season_index_for_day(owner._last_day)
	if season != owner._last_season:
		owner._last_season = season
		owner.season_changed.emit(season)
	var year: int = owner.year_index_for_day(owner._last_day)
	if year != owner._last_year:
		owner._last_year = year
		owner._apply_year_rollover(year)
	owner._publishing_runtime_date = false


static func _process_runtime_calendar(owner: Variant, delta: float) -> void:
	owner._runtime_calendar_fraction += delta * owner.speed_multiplier
	var elapsed_days := int(owner._runtime_calendar_fraction)
	owner._runtime_calendar_fraction -= elapsed_days
	if elapsed_days > 0:
		owner._runtime_calendar_through = int(owner._runtime_calendar_admit.call(
			owner._runtime_calendar_through + elapsed_days + 1))
	owner.current_day = float(owner._last_day) + owner._runtime_calendar_fraction
	var dp: float = owner.day_phase()
	if owner._should_emit_day_phase(dp):
		owner._last_emit_day_phase = dp
		owner.day_phase_changed.emit(dp)
	var sp: float = owner.season_phase()
	if owner._should_emit_season_phase(sp):
		owner._last_emit_season_phase = sp
		owner.season_phase_changed.emit(sp)
	owner._advance_visual_day_phase(delta)


static func _process(owner: Variant, delta: float) -> void:
	if owner.authority_fault_hold:
		owner.paused = true
		return
	if owner.paused or owner.speed_multiplier <= 0.0:
		return
	if owner._runtime_calendar_admit.is_valid():
		owner._process_runtime_calendar(delta)
		return
	var proc_start_us: int = Time.get_ticks_usec()
	# 自初始化兜底：_emit_initial_signals（call_deferred）可能晚于首帧 _process。
	# _last_day 仍是 -1 哨兵时，先对齐到当前整日，避免 current_day 派生出负值。
	if owner._last_day < 0:
		owner._last_day = int(floor(owner.current_day))
		owner._day_carry = owner.current_day - float(owner._last_day)
	# best-effort 吞吐模型（plan/best-effort-sim-stepping）：倍速 = 目标天/秒。
	# 本帧目标推进量先按硬上限封顶——即便上一帧卡顿导致 delta 巨大，也不会把
	# 成百天一次性灌进来点燃死亡螺旋。
	# 软 backpressure（非 *_day_barrier 的来源）只是诊断信号，不参与限流。它只能由
	# 日推进本身清除，一旦拿来砍倍速就会自锁：降速 → 更少日推进 → 更晚清除。
	# 硬 barrier 不同：它只在冻结周期的结算截止点抬起，必须停下新的一天，并发一次
	# 真实帧 pulse 让同日 catchup 收尾。
	var simulation_budget_start_us: int = Time.get_ticks_usec()
	if owner._worker_lag_over_budget():
		owner._lag_blocked_frames += 1
	var hard_day_barrier: bool = owner._day_advance_blocked_by_barrier()
	var pulse_start_us: int = Time.get_ticks_usec()
	# climate_input_capacity_day_barrier parks day advance only. Capacity is
	# freed by the worker draining the environment ring while WorldRuntimeHost
	# pumps peers and retries the retained day — NOT by MapGenerator's economy
	# graph pulse. Emitting pulse here re-ran capture_economy_day_inputs every
	# frame (often 20–30ms) and starved the capacity retry, permanently nailing
	# the calendar at 50x with a full ring.
	if hard_day_barrier and owner.needs_continuation_pulse():
		owner.simulation_backpressure_pulse.emit(owner._last_day)
		# 重读必须走同一个判定：pulse 只清 continuation 那一类 source，
		# 限额打满（或限流模式下的豁免）仍必须生效。
		hard_day_barrier = owner._day_advance_blocked_by_barrier()
	owner._last_pulse_ms = float(Time.get_ticks_usec() - pulse_start_us) / 1000.0
	# pulse 已经吃满帧预算时才把新的一天让给下一帧，避免 pulse + 完整日 tick 叠成
	# 尖峰。pulse 很便宜时当帧继续推进，不再为"曾经有过 barrier"额外罚一帧。
	var sim_budget: float = owner.sim_budget_ms()
	var blocked: bool = hard_day_barrier or owner._last_pulse_ms >= sim_budget
	# 连续限流：每帧推进天数上限 = 帧预算 / 实测单日成本。单日 8ms 以内不封顶，
	# 单日 80ms 时降到 0.1 天/帧——吞吐平滑下降而帧率守住，代替旧的倍速悬崖。
	var throughput_cap := float(owner.max_sim_days_per_frame)
	if owner._day_cost_ms_ema > 0.0:
		throughput_cap = clampf(sim_budget / owner._day_cost_ms_ema,
			owner._MIN_THROUGHPUT_DAYS_PER_FRAME, float(owner.max_sim_days_per_frame))
	owner._last_throughput_cap = throughput_cap
	var target: float = 0.0 if blocked else minf(delta * owner.speed_multiplier, throughput_cap)
	owner._day_carry += target

	# 时间盒 + 硬上限：本帧最多推进 max_sim_days_per_frame 天，且至少跑满 1 天后
	# 一旦累计耗时超预算就停。每个 _advance_one_sim_day 会同步触发 _on_day_changed
	# → 一个完整 SUS tick，所以这里的墙钟测量天然涵盖当日全部模拟 + 渲染同步成本。
	var t0_us: int = Time.get_ticks_usec()
	var ran: int = 0
	while not owner.paused and not blocked and owner._day_carry >= 1.0 and ran < owner.max_sim_days_per_frame:
		# 时间盒从 continuation pulse 之前开始计时；无 pulse 的普通帧仍保证至少推进
		# 一天，保持低倍速/轻负载吞吐行为不变。
		if ran > 0 and float(Time.get_ticks_usec() - simulation_budget_start_us) / 1000.0 \
				>= sim_budget:
			break
		owner._day_carry -= 1.0
		owner._advance_one_sim_day()
		ran += 1
		# A day_changed handler may have raised a country/economy settlement
		# barrier. Re-read it before this render frame advances another day.
		# 限额同理：一天推完之后 worker 的提交水位可能已经变化，同一帧内
		# 保守地一起重读，避免一帧里把领先量拉过上限。
		blocked = owner._day_advance_blocked_by_barrier()

	# best-effort：本帧没追完的整数天直接丢弃，只保留 < 1 天的小数 carry。这是杜绝
	# spiral 的关键——债务永不累积，过载时有效倍速平滑降级、FPS 保持稳定。
	if owner._day_carry >= 1.0:
		owner._day_carry -= floor(owner._day_carry)

	# best-effort 诊断（临时，plan/best-effort-sim-stepping）：本帧推进了几天、
	# 日循环花了多久。和 render-profile 的 sus_frame_avg(~45ms) 对比即可定位：
	#   loop_ms ≈ proc_ms ≪ 45ms  → 35ms 在 _process 之外（渲染/present GPU 同步）。
	#   loop_ms ≈ 45ms            → 日循环本身超预算（budget 失效或单日 >预算）。
	owner._rate_frames += 1
	owner._rate_delta_sum += delta
	owner._rate_days += ran
	if blocked:
		owner._rate_blocked += 1
	if ran > 0 and float(Time.get_ticks_usec() - simulation_budget_start_us) / 1000.0 >= sim_budget:
		owner._rate_budget_break += 1
	if owner._rate_next_msec == 0:
		owner._rate_next_msec = Time.get_ticks_msec() + 2000
	elif Time.get_ticks_msec() >= owner._rate_next_msec:
		var span_s := maxf(0.001, float(owner._rate_frames) * (owner._rate_delta_sum / float(maxi(1, owner._rate_frames))))
		# [clock/rate] 每 2 秒一行实测吞吐：天数/秒、日成本、节流上限、平均帧率。
		# 排查"×10 到底有没有 10 天/秒"直接看这一行，不用再心算 heartbeat 差值。
		print("[clock/rate] dps=%.2f speed=%.0fx cap=%.2fd/f cost=%.0fms fps=%.1f blocked=%d budget_break=%d"
			% [float(owner._rate_days) / span_s, owner.speed_multiplier, owner._last_throughput_cap,
				owner._day_cost_ms_ema, float(owner._rate_frames) / span_s, owner._rate_blocked, owner._rate_budget_break])
		WebTelemetry.emit("clock_rate", {
			"frames": owner._rate_frames,
			"days": owner._rate_days,
			"blocked": owner._rate_blocked,
			"budget_break": owner._rate_budget_break,
			"cap": snappedf(owner._last_throughput_cap, 0.01),
			"cost": int(owner._day_cost_ms_ema),
			"dps": snappedf(float(owner._rate_days) / span_s, 0.01),
			"speed": owner.speed_multiplier,
		})
		WebTelemetry.flush()
		owner._rate_frames = 0
		owner._rate_blocked = 0
		owner._rate_budget_break = 0
		owner._rate_days = 0
		owner._rate_delta_sum = 0.0
		owner._rate_next_msec = Time.get_ticks_msec() + 2000
	owner._last_advanced_days = ran
	owner._last_loop_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	# 单日成本 EMA 的样本 = 本帧模拟总墙钟（含 continuation pulse）/ 实际推进天数。
	# 只在真正推进过日子的帧采样；纯 barrier 帧没有可归属的天数。
	if ran > 0:
		var per_day_ms := float(Time.get_ticks_usec() - simulation_budget_start_us) \
			/ 1000.0 / float(ran)
		owner._day_cost_ms_ema = per_day_ms if owner._day_cost_ms_ema <= 0.0 else \
			owner._day_cost_ms_ema + owner._DAY_COST_EMA_ALPHA * (per_day_ms - owner._day_cost_ms_ema)

	# current_day 派生：已模拟整数日 + 小数 carry。低速（target<1）下 carry 平滑累加，
	# 驱动 day_phase/season_phase 连续过渡；高速下小数部分无实际意义但无害。
	# season/year 已在 _advance_one_sim_day 内逐日处理，这里不再重复检测。
	owner.current_day = float(owner._last_day) + owner._day_carry
	# 任务 2：day_phase 节流发射
	var dp: float = owner.day_phase()
	if owner._should_emit_day_phase(dp):
		owner._last_emit_day_phase = dp
		owner.day_phase_changed.emit(dp)
	# Fast-tick perf opt (D)：season_phase 同款节流发射。
	var sp: float = owner.season_phase()
	if owner._should_emit_season_phase(sp):
		owner._last_emit_season_phase = sp
		owner.season_phase_changed.emit(sp)

	# [cylindrical-earth-daylight] 推进视觉昼夜（晨昏线）相位，按真实 delta 匀速绕圈，
	# 与 speed_multiplier 解耦 → 快进时晨昏线移动速度不变，杜绝全屏明暗闪烁。
	owner._advance_visual_day_phase(delta)

	# best-effort 诊断打印（临时）：每 ~120 个 _process 帧打一行，含 delta、目标天、
	# 实际推进天数 ran、continuation 脉冲段墙钟 pulse、日循环墙钟 loop、
	# 整个 _process 墙钟 full（含 pulse + loop + 相位信号）。
	owner._last_full_proc_ms = float(Time.get_ticks_usec() - proc_start_us) / 1000.0
	if owner.debug_step_log and Engine.get_process_frames() % 120 == 0:
		var barrier_names := PackedStringArray()
		for key in owner._simulation_backpressure_sources.keys():
			barrier_names.append(String(key))
		barrier_names.sort()
		print("[clock/step] delta=%.1fms speed=%.0fx target=%.2fd cap=%.2fd/f cost=%.2fms ran=%d pulse=%.2fms loop=%.2fms full=%.2fms carry=%.2f barrier=%s"
			% [delta * 1000.0, owner.speed_multiplier, delta * owner.speed_multiplier,
				owner._last_throughput_cap, owner._day_cost_ms_ema, ran,
				owner._last_pulse_ms, owner._last_loop_ms, owner._last_full_proc_ms, owner._day_carry,
				",".join(barrier_names)])
		if ran > 0 and owner._last_loop_ms >= sim_budget and not owner._last_fat_slice_diag.is_empty():
			print("[clock/fat-day] loop=%.2fms largest=%.2fms job=%s stage=%s over_budget=%s native_stage=%s"
				% [owner._last_loop_ms,
					float(owner._last_fat_slice_diag.get("largest_slice_ms", 0.0)),
					str(owner._last_fat_slice_diag.get("largest_slice_job", "")),
					str(owner._last_fat_slice_diag.get("largest_slice_stage", "")),
					str(owner._last_fat_slice_diag.get("commit_over_budget", false)),
					str(owner._last_fat_slice_diag.get("native_stage", ""))])
	# Web 单日成本探针：本帧最后一个日桶到这里一定已跑完（day_changed 同步派发），
	# 帧尾补发一次。已经在 _advance_one_sim_day 开头发过的桶是空的，不会重复。
	if owner.day_cost_probe_on:
		owner.day_cost_flush()
