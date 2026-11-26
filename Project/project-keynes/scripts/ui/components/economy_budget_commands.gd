extends RefCounted

## Applies government procurement and military budget commands.


static func _on_procurement_committed(owner: EconomyWorkspace, treasury_share_bp: int, research_share_bp := -1,
		era_share_bp := -1, colonization_share_bp := -1) -> void:
	var research_share := research_share_bp
	if research_share < 0:
		if owner._fiscal_page != null and owner._fiscal_page.technology_slider() != null:
			research_share = int(owner._fiscal_page.technology_slider().share_bp())
		elif owner._fiscal_page != null and owner._fiscal_page.national_slider() != null:
			research_share = int(owner._fiscal_page.national_slider().research_share_bp())
		else:
			research_share = EconomyWorkspace.NationalProcurementSliderScript.DEFAULT_RESEARCH_SHARE_BP
	var result: Dictionary = EconomyWorkspace.NationalProcurementSliderScript.submit_policy(owner._player_controller,
		treasury_share_bp, research_share, era_share_bp, colonization_share_bp)
	var ok := bool(result.get("ok", false))
	if ok:
		owner._set_status("预算份额已提交")
	else:
		var message := String(result.get("message", result.get("reason", ""))).strip_edges()
		if EconomyWorkspace.NationalProcurementSliderScript.is_unsupported(result):
			message = "预算调配将在国库建制后启用。"
		owner._set_status(message if not message.is_empty() else "预算份额提交失败", true)
	if owner._fiscal_page != null:
		if ok:
			owner._fiscal_page.set_local_policy(treasury_share_bp, research_share,
				era_share_bp, colonization_share_bp)
		else:
			# 失败不留覆盖：刷新会把滑条退回原生真实政策，玩家看到的就是真相。
			owner._fiscal_page.clear_local_policy()
		owner._fiscal_page.refresh_live(owner._model)


## 军事预算提交（任务 9）：把板块发来的份额意图转成 `military.policy.set_budget`。
## `-1` 原样往上传，原生按未传入项沿用当前值校验三项份额之和 <= 100%。
## 提交成功才写本地覆盖，让滑条在快照跟上之前不被弹回旧值。
static func _on_military_budget_committed(owner: EconomyWorkspace, total_bp: int, wage_bp: int, upkeep_bp: int,
		procurement_bp: int) -> void:
	if owner._player_controller == null or not owner._player_controller.has_method("request_command"):
		owner._set_status("玩家尚未就绪，军事预算未能提交", true)
		return
	var args := {"total_bp": int(total_bp)}
	if wage_bp >= 0:
		args["wage_bp"] = int(wage_bp)
	if upkeep_bp >= 0:
		args["upkeep_bp"] = int(upkeep_bp)
	if procurement_bp >= 0:
		args["procurement_bp"] = int(procurement_bp)
	var result: Dictionary = owner._player_controller.request_command(
		EconomyWorkspace.PlayerControllerScript.COMMAND_MILITARY_BUDGET, args)
	if bool(result.get("ok", false)):
		if owner._fiscal_page != null:
			owner._fiscal_page.set_local_military_budget(
				int(total_bp), wage_bp, upkeep_bp, procurement_bp)
			owner._fiscal_page.refresh_live(owner._model)
		if wage_bp >= 0 or upkeep_bp >= 0 or procurement_bp >= 0:
			owner._set_status("军事预算与通道份额已提交")
		else:
			owner._set_status("军事预算已提交")
		return
	var message := String(result.get("message", result.get("reason", ""))).strip_edges()
	var code := String(result.get("code", ""))
	if code == "unsupported_command":
		message = "军费统筹尚未设立：先在军事页建立统辖机构，方可调配军费"
	elif code == "command_budget_channels_exceed_10000":
		message = "三项通道份额之和超过 100%，请下调任一项"
	elif code.is_empty() and message.is_empty():
		message = "军事预算提交失败"
	owner._set_status(message, true)
	# 失败不留覆盖：下一次刷新把滑条退回原生真实政策，玩家看到的就是真相。
	if owner._fiscal_page != null:
		owner._fiscal_page.refresh_live(owner._model)
