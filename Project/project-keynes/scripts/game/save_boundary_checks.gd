extends RefCounted

const ArchiveContract = preload("res://scripts/game/save_archive_contract.gd")

## Examines the committed simulation and its idle-save prerequisites.


static func _boundary_diagnostics(owner) -> Dictionary:
	var out := {"day": owner._world_clock.day_index() if owner._world_clock != null else -1}
	var generator = owner._runtime_host.generator() if owner._runtime_host != null else null
	if generator == null:
		return out
	var economy = generator.get_economy_facade()
	if economy != null:
		var report: Dictionary = economy.report()
		out["economy"] = {"busy": report.get("busy", null),
			"epoch_active": report.get("epoch_active", null),
			"committed": report.get("committed", null),
			"last_committed_day": report.get("last_committed_day", null)}
	var country = generator.get_country_facade()
	# 存档边界最常卡的就是 country：把「谁在拥有 country」和「country_should_run
	# 为什么还是 true」一起记下来，否则只有一句 save_requires_idle_country
	# 根本定位不了（web 的 pause 期间没有任何日推进者）。
	if country != null:
		var country_report: Dictionary = country.report()
		out["country_busy"] = bool(country_report.get("busy", false))
		out["country_stage"] = String(country_report.get("stage", ""))
	if generator.has_method("runtime_graph_active"):
		out["runtime_graph_active"] = bool(generator.runtime_graph_active())
	if country != null and country.world_ext() != null:
		out["country_peer"] = country.peer_protocol_status()
		out["country_should_run"] = country.should_run(int(out["day"]))
	if generator.has_method("get_runtime_thread_report"):
		var thread: Dictionary = generator.get_runtime_thread_report()
		for key in ["simulation_host_state", "simulation_committed_day", "environment_ring_pending",
				"worker_day_inflight", "day_stall_reason_mask", "fault_code",
				"country_worker_plan_active", "country_worker_waiting_for_peer"]:
			out[key] = thread.get(key, null)
	var effect = generator.get_effect_facade()
	if effect != null and effect.world_ext() != null:
		out["effect_adapters"] = effect.native_adapter_report()
	return out



static func _can_save(owner) -> Dictionary:
	if owner._runtime_host == null or owner._world_clock == null \
			or not owner._session_active(owner._runtime_generation) \
			or owner._runtime_host.generator() == null:
		return ArchiveContract.result(false, "save_runtime_missing", "游戏尚未就绪，请稍后再试。")
	var generator: MapGenerator = owner._runtime_host.generator()
	var country_has_checkpoint := false
	if generator.has_method("get_runtime_thread_report"):
		var thread: Dictionary = generator.get_runtime_thread_report()
		country_has_checkpoint = bool(thread.get("country_worker_authoritative", false))
		if owner._runtime_host.is_runtime_fault_paused() or String(thread.get("simulation_host_state", "")) == "FAULTED":
			return ArchiveContract.blocked_result("worker_faulted", "后台模拟线程发生故障（%s），无法保存。" %
				String(owner._runtime_host.get_runtime_fault_diagnostics().get("fault_code", thread.get("fault_code", "unknown"))), "worker_faulted")
		var idle_blocker: String = owner._worker_idle_blocker(thread)
		if not idle_blocker.is_empty():
			return ArchiveContract.blocked_result("save_requires_idle_worker",
				"等待后台 worker 排空已接收的模拟输入。", idle_blocker)
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	if country == null or economy == null:
		return ArchiveContract.result(false, "save_provider_missing", "国家或经济 provider 未注册。")
	var country_report: Dictionary = country.report()
	var economy_report: Dictionary = economy.report()
	var effect = generator.get_effect_facade()
	# The Effect owner is persisted independently from the domain owners.  Do
	# not capture PKEF/PKCN/PKEC/journal while a native POD request has crossed
	# Effect preflight but has not received the owning domain's durable ACK.
	if effect != null and effect.world_ext() != null:
		var adapters: Dictionary = effect.native_adapter_report()
		# The host checkpoint carries pending Country packets and their Effect
		# receipt bindings. Future-day commands cannot drain with the clock paused.
		if not country_has_checkpoint and bool(adapters.get("country_pending", false)):
			return ArchiveContract.blocked_result("save_requires_idle_effect_country",
				"等待理念/Effect Country 命令提交", "effect_country_pending")
		if bool(adapters.get("economy_pending", false)):
			return ArchiveContract.blocked_result("save_requires_idle_effect_economy",
				"等待理念/Effect Economy 命令提交", "effect_economy_pending")
		if bool(adapters.get("gameplay_pending", false)):
			return ArchiveContract.blocked_result("save_requires_idle_effect_gameplay",
				"等待理念/Effect Gameplay 事件写入 journal", "effect_gameplay_pending")
	# 已提交账本契约（写档和读档都一样）要求经济至少结算过一次；开局到首次结算
	# 之间没有可恢复的状态。这里不进重试列表：时钟为存档暂停，等下去也不会到。
	if int(economy_report.get("last_committed_day", -1)) < 0:
		return ArchiveContract.result(false, "save_requires_first_settlement",
			"经济尚未完成第一次结算，暂时无法存档。请让游戏运行几天后再保存。")
	var economy_busy := bool(economy_report.get("busy",
		economy_report.get("epoch_active", false)))
	if economy_busy or not bool(economy_report.get("committed", true)):
		return ArchiveContract.blocked_result("save_requires_committed_boundary",
			"经济尚未到达联合提交边界。",
			"economy_busy" if economy_busy else "economy_not_committed")
	var country_busy := bool(country_report.get("busy", false))
	var country_ext_available := country.world_ext() != null
	if country_ext_available:
		var peer_status: Dictionary = country.peer_protocol_status()
		if int(peer_status.get("pending_intents", 0)) > 0 \
			or int(peer_status.get("queued_intents", 0)) > 0 \
			or int(peer_status.get("rejected_intents", 0)) > 0:
			return ArchiveContract.blocked_result("save_requires_idle_country_peer",
				"Country peer continuation 尚未到达可保存边界。", "country_peer_intents")
	# The checkpoint includes future commands. The calendar is one day ahead
	# of the committed state and must not drive the synchronous Country store.
	if not country_has_checkpoint:
		if country_ext_available:
			country_busy = country_busy or country.should_run(owner._world_clock.day_index())
		else:
			country_busy = country_busy or String(country_report.get("stage", "idle")) == "command_preflight"
	if country_busy:
		# 三个来源：report.busy / country_should_run(day) / 无扩展时的
		# command_preflight。日志里必须能分开，否则又是一句"国家没空闲"。
		var country_condition := "country_busy"
		if not bool(country_report.get("busy", false)):
			if country_ext_available:
				country_condition = "country_should_run"
			else:
				country_condition = "country_command_preflight"
		return ArchiveContract.blocked_result("save_requires_idle_country", "国家命令图尚未空闲。",
			country_condition)
	if effect != null and effect.world_ext() != null \
			and effect.should_run(owner._world_clock.day_index()):
		return ArchiveContract.blocked_result("save_requires_idle_effect",
			"Effect transaction has not reached a safe commit boundary",
			"effect_should_run")
	var ideology = generator.get_ideology_facade() if generator.has_method("get_ideology_facade") else null
	var ideology_ext_available := ideology != null and ideology.world_ext() != null
	if ideology_ext_available \
			and ideology.should_run(owner._world_clock.day_index()):
		return ArchiveContract.blocked_result("save_requires_idle_ideology",
			"Ideology commands have not reached their safe boundary",
			"ideology_should_run")
	return ArchiveContract.result(true, "ok", "")


## 返回阻塞原因或空串。inline 没有后台循环更新 RUNNING，按真实日边界判断；
## 尚未消费的未来环境帧交给 native 保存服务清空。
static func _worker_idle_blocker(thread: Dictionary) -> String:
	var host_state := String(thread.get("simulation_host_state", "STOPPED"))
	if bool(thread.get("native_daily_inline", false)) and host_state in ["RUNNING", "PAUSED"]:
		if int(thread.get("worker_day_inflight", 0)) > 0:
			return "worker_day_inflight"
		return "inline_day_pending" if bool(thread.get("inline_day_pending", false)) else ""
	if host_state in ["STARTING", "RUNNING", "SAVE_PENDING"]:
		return "state_%s" % host_state.to_lower()
	if int(thread.get("worker_day_inflight", 0)) > 0:
		return "worker_day_inflight"
	return ""
