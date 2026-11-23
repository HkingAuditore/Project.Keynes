extends RefCounted

static func _demolish_result_message(code: String) -> String:
	return {
		"ok": "拆除已完成。",
		"construction_cell_not_owned": "目标地块已不属于玩家国家。",
		"demolish_queued": "拆除已排队，将在下一个经济结算边界执行。",
		"demolish_target_invalid": "拆除目标无效。",
		"demolish_not_state_owned": "该建筑不属于官营，无法按官营方式拆除。",
		"demolish_state_owner_unresolved": "官营属主未能解析，请检查建筑与职业目录。",
		"demolish_state_building_absent": "该地块上已没有这座官营建筑。",
		"demolish_owned_count_insufficient": "该地块的这座建筑座数不足。",
		"unsupported_ownership_policy": "当前版本不支持该产权策略。",
		"economy_not_bootstrapped": "经济系统尚未就绪，请稍后再试。",
		"economy_fatal": "经济模拟已停止，无法执行拆除。",
		"save_restore_active": "存档正在读写，稍后再试。",
	}.get(code, "拆除命令未能执行。")


static func _colonization_result_message(code: String) -> String:
	return {
		"STARTED": "开拓队已经出发。",
		"CANCELLED_RETURNING": "开拓已取消，队伍正在返程。",
		"TARGET_LOST_RETURNING": "目标已被占领，队伍正在返程。",
		"PREPARING_UNBUILDABLE": "源地缺少开工包所需建材且无法获得，筹备已中止，托管物资已退回。",
		"CLAIMED": "开拓成功，目标已纳入领土。",
		"RELOCATED": "迁徙成功，人员已并入目标地块。",
		"RETURNED": "开拓队已返回原出发地。",
		"colonization_requote_required": "地图、视野或领土已变化，排队派遣未能出发。",
		"colonization_route_not_visible": "开拓路线已不在视野内，队伍未能出发。",
		"colonization_route_territory_invalid": "开拓路线的领土已变化，队伍未能出发。",
		"colonization_route_not_passable": "开拓路线已无法通行，队伍未能出发。",
		"colonization_expedition_invalid": "找不到这支可以取消的开拓队。",
		"colonization_population_insufficient": "结算时源分支人口已不足，排队派遣未能出发。",
		"colonization_duplicate_target": "本国已有队伍前往该目标，排队派遣未能出发。",
		"colonization_family_cell_capacity": "目标地块家族已满，排队派遣未能出发。",
	}.get(code, "开拓队状态已更新。")


static func _construction_result_message(code: String) -> String:
	return {
		"ok": "建筑已开工。",
		"construction_cell_not_owned": "目标地块已不属于玩家国家。",
		"construction_technology_locked": "建造所需科技尚未解锁。",
		"technology_locked": "建造所需科技尚未解锁。",
		"military_construction_schedule_full": "当地官营建筑的营造排期已满。",
		"construction_obsolete": "已有更高阶生产方式；当前方式仍可建造。",
		"construction_conditions_failed": "目标地块不满足建筑放置条件。",
		"construction_resource_unavailable": "当地自然资源承载不足。",
		"construction_materials_insufficient": "国库与当地市场的建材总量不足。",
		"construction_treasury_cash_insufficient": "国库资金不足以购买缺少的建材。",
		"construction_market_unavailable": "当地市场没有可结算的商人。",
		"construction_owner_signature_unavailable": "本地没有合适的业主人口。",
		"construction_target_invalid": "目标建筑无效。",
		"political_regime_lacks_treasury_construction": "当前体制不开放国库建造。",
		"construction_treasury_preflight_drift": "国库结算与营造报价不一致，请重试。",
		"country_economy_asset_host_pending": "国库结算尚未完成，请稍后重试。",
		"economy_not_bootstrapped": "经济系统尚未就绪，请稍后再试。",
		"economy_fatal": "经济模拟已停止，无法营造。",
		"save_restore_active": "存档正在读写，稍后再试。",
		"unsupported_ownership_policy": "当前版本不支持该产权策略。",
	}.get(code, "修建命令未能执行（%s）。" % code)
