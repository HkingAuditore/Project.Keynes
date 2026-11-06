extends RefCounted
var _pending_load_bundle: Dictionary
var _generator
var _current_map
var _world_clock
var _session_prepare_options: Dictionary
var service
var emit_failure: Callable
var failure: Callable
func _game_save_service() -> Object: return service
func _emit_world_generation_failure(a,b,c,d): emit_failure.call(a,b,c,d)
func _session_preparation_failure(): return failure.call()

func _prepare_world_restore() -> Dictionary:
	if not _pending_load_bundle.is_empty():
		_generator._runtime_climate_catalog_hash_for_map(_current_map) # Before dynamic terrain restore.
		var save_service: Object = _game_save_service()
		var restore_result: Dictionary = save_service.restore_prepared_game(self) if save_service != null \
			else {"ok": false, "message": "存档服务不可用。"}
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
			_emit_world_generation_failure("save_restore", "save_restore_failed",
				String(restore_result.get("message", "存档恢复失败。")),
				"存档可能损坏或与当前版本不兼容；code=%s%s" % [restore_code,
					"" if restore_detail.is_empty() else "；" + restore_detail])
			return _session_preparation_failure()
		# 运行中保存的时钟会恢复为 unpaused；随后仍有数个加载 await。
		# 在输入捕获/worker 启动完成前推进日历会漏掉环境输入并卡住日屏障。
		if _world_clock != null:
			_session_prepare_options.clock_was_paused = _world_clock.paused
			_world_clock.pause(true)
		_pending_load_bundle.clear()
	return {"ok": true}

