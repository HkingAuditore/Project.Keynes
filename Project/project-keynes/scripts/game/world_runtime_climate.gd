extends RefCounted

## Climate publication diagnostics for the recorder and development tools.

func climate_authority_diagnostics(host) -> Dictionary:
	var report: Dictionary = host._generator.get_runtime_thread_report() \
		if host._generator != null and host._generator.has_method("get_runtime_thread_report") \
		else {}
	return {
		"enabled": host._native_environment_active,
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
	}
