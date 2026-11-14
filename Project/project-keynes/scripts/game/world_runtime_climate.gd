extends RefCounted

## Climate authority policy and worker handoff. Mutable state remains on the host.

func _try_promote_economy_pod_active(host) -> void:
	if not host.runtime_economy_auto_pod_active:
		return
	if host._generator == null or not host._generator.has_method("get_data_core_world_ext"):
		return
	var ext = host._generator.get_data_core_world_ext()
	if ext == null:
		return
	var report: Dictionary = host._generator.get_runtime_thread_report() \
		if host._generator.has_method("get_runtime_thread_report") else {}
	if String(report.get("simulation_thread_mode", "OFF")) != "ACTIVE":
		return
	if not bool(report.get("economy_pod_active_ready", false)):
		return
	# Already bound OwnedState means POD_ACTIVE promotion has landed.
	if String(report.get("economy_formula_backing", "")) == "owned_state":
		return
	# Cheap prefilter; C++ still try_locks because this races with the worker.
	if int(report.get("worker_day_inflight", 0)) != 0 \
			or int(report.get("economy_inflight_mutations", 0)) != 0:
		return
	var switched: Dictionary = ext.switch_economy_authority("POD_ACTIVE")
	if bool(switched.get("ok", false)):
		print("[runtime-worker] Economy authority promoted to POD_ACTIVE")


## 运行时开关 Climate|Country 权威。关掉后停掉 ACTIVE worker、改以 SHADOW 重启，
## 主线程立刻恢复算 climate/country。打开则相反。不需要重新生成世界。
## B8-4：这个入口现在等价于 force_on / force_off；想回到 auto 用
## set_climate_authority_override("auto")。

func set_runtime_climate_authority_enabled(host, enabled: bool) -> Dictionary:
	host.runtime_climate_authority_enabled = enabled
	host._climate_authority_policy.set_force_enabled(enabled)
	return host._restart_worker_with_current_policy()


func _restart_worker_with_current_policy(host) -> Dictionary:
	return host._lifecycle.restart_worker_with_current_policy(host)


## B8-4：三态策略入口。auto 交给实测阈值，force_on/force_off 覆盖它。

func set_climate_authority_override(host, mode: String) -> Dictionary:
	var applied: Dictionary = host._climate_authority_policy.set_override_mode(mode)
	if not bool(applied.get("ok", false)):
		return applied
	# override 只决定"模式"，不覆写会话 request（诊断要能同时看到"想开"与"实际
	# 生效"）。重启路径自己会重新解析策略，避免半状态。
	var restarted: Dictionary = host._restart_worker_with_current_policy()
	return {
		"ok": bool(restarted.get("ok", true)),
		"code": String(restarted.get("code", "ok")),
		"override": mode,
		"policy": host._resolve_climate_authority_policy(),
		"diagnostics": restarted,
	}


## 解析当前策略（不改状态）。诊断与启动路径共用同一个函数，避免两处判据漂移。

func _resolve_climate_authority_policy(host) -> Dictionary:
	var n_cells = host._current_map.cell_count() if host._current_map != null else 0
	return host._climate_authority_policy.resolve(host.runtime_climate_authority_enabled, n_cells)


## Climate|Country 权威诊断。供 dev console / 对拍场景读，不参与调度决策。

func climate_authority_diagnostics(host) -> Dictionary:
	var report: Dictionary = host._generator.get_runtime_thread_report() \
		if host._generator != null and host._generator.has_method("get_runtime_thread_report") \
		else {}
	return {
		"enabled": host.runtime_climate_authority_enabled,
		"worker_authoritative": bool(report.get("climate_worker_authoritative", false)),
		"country_worker_authoritative": bool(report.get(
			"country_worker_authoritative", false)),
		"authoritative_domain_mask": int(report.get("authoritative_domain_mask", 0)),
		"requested_authority_mask": int(report.get("requested_authority_mask", 0)),
		"writeback_generation": host._runtime_climate_writeback_generation,
		"writeback_days": host._runtime_climate_writeback_days,
		"writeback_last_day": host._runtime_climate_writeback_last_day,
		"writeback_applied_fields": host._runtime_climate_writeback_applied_fields,
		"writeback_skipped_fields": host._runtime_climate_writeback_skipped,
		# B8 P0：交付游标与回灌分段耗时。writeback_days 只说明"回灌落地几天"，
		# 这几条才区分"worker 没消费"（superseded/consumed 落后 published）与
		# "回灌本身慢"（memcpy/flush）。
		"climate_committed_day": int(report.get("climate_committed_day", -1)),
		"climate_consumed_generation": int(report.get(
			"climate_consumed_generation", 0)),
		"environment_published_days": int(report.get(
			"environment_published_days", 0)),
		"environment_consumed_days": int(report.get(
			"environment_consumed_days", 0)),
		"environment_superseded_days": int(report.get(
			"environment_superseded_days", 0)),
		"environment_dropped_days": int(report.get(
			"environment_dropped_days", 0)),
		"environment_ring_pending": int(report.get(
			"environment_ring_pending", 0)),
		"climate_wait_total_ms": int(report.get("climate_wait_total_ms", 0)),
		"climate_wait_last_ms": int(report.get("climate_wait_last_ms", 0)),
		"climate_wait_max_ms": int(report.get("climate_wait_max_ms", 0)),
		"writeback_memcpy_ms": float(host._runtime_climate_writeback_memcpy_ms),
		"writeback_flush_ms": float(host._runtime_climate_writeback_flush_ms),
		"writeback_drop_count": int(host._runtime_climate_writeback_drops),
		"authority_policy": host._resolve_climate_authority_policy(),
	}


## 视觉 intent 的兼容适配点。worker 只发布数值 intent；具体 MapData/GPU
## 更新仍留在主线程。当前未迁移的 family 不做隐式写入，避免误把 probe
## 数据当成权威状态。
