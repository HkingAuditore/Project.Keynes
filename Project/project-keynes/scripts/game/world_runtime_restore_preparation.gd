extends RefCounted

# Passive restore preparation. No retained host, process, signal or new await.
static func prepare(bundle: Dictionary, generator: Object, map_data,
        restore: Callable, clock: Object, options: Dictionary,
        emit_failure: Callable, failure: Callable) -> Dictionary:
	if not bundle.is_empty():
		generator._runtime_climate_catalog_hash_for_map(map_data) # Before dynamic terrain restore.
		var restore_result: Dictionary = restore.call()
		if not bool(restore_result.get("ok", false)):
			var restore_code := String(restore_result.get("code", "unknown"))
			var restore_detail := String(restore_result.get("detail", ""))
			push_error("[save/restore] load failed code=%s message=%s detail=%s" % [
				restore_code,
				String(restore_result.get("message", "存档恢复失败。")),
				restore_detail,
			])
			# 失败 hint 落到新档/自动存档的诊断文件里：只给 code 不足以远程定位，
			# 起始格/镜像/native 摘要由 finalize_save_restore_visuals 通过 detail 带出。
			emit_failure.call("save_restore", "save_restore_failed",
				String(restore_result.get("message", "存档恢复失败。")),
				"存档可能损坏或与当前版本不兼容；code=%s%s" % [restore_code,
					"" if restore_detail.is_empty() else "；" + restore_detail])
			return failure.call()
		# 运行中保存的时钟会恢复为 unpaused；随后仍有数个加载 await。
		# 在输入捕获/worker 启动完成前推进日历会漏掉环境输入并卡住日屏障。
		if clock != null:
			options.clock_was_paused = clock.paused
			clock.pause(true)
		bundle.clear()
	return {"ok": true}

