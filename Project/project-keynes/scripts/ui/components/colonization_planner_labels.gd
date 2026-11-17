extends RefCounted

const ROUTE_BLOCKED_SHORT := "路线被水域或不可通行地形隔断，本国没有城市能连通此地。"

const ROUTE_WATER_HINT := "跨水需要「河运」（湖泊）、「天文导航」（浅海）、「远洋航海」（远海）或「远洋船舶设计」（深海）。"

static func _state_text(state: int) -> String:
	return {1: "前往中", 2: "落地结算中", 3: "返程中", 4: "筹备中"}.get(state, "未知")


static func _diagnostic_message(code: String, raw_message: String) -> String:
	var raw := raw_message.strip_edges()
	if raw.begins_with("colonization_") or raw.begins_with("PREPARING_"):
		return _reason_text(raw)
	if not raw.is_empty():
		return raw
	return _reason_text(code) if not code.is_empty() else ""


static func _reason_text(code: String) -> String:
	return {
		"colonization_target_invalid": "目标必须是当前可见、可通行的无主或本国陆地。",
		"colonization_route_unreachable": ROUTE_BLOCKED_SHORT + ROUTE_WATER_HINT,
		"colonization_route_not_passable": "目标或途经地块不可通行：" + ROUTE_WATER_HINT,
		"colonization_route_not_visible": "路线经过尚未探索的地块，请先扩大视野。",
		"colonization_route_territory_invalid": "路线会经过他国领土，无法通行。",
		"colonization_route_water_invalid": "水域航道无法还原，请重新选择目的地。",
		"colonization_route_expansion_limit": "目标过远，路线搜索超出预算，请选择更近的目的地。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
		"colonization_preparing": "开拓队已开始筹备，人仍留在源地生产缺货物资。",
		"colonization_cancelled": "开拓筹备已取消，目标占用已释放。",
		"PREPARING_UNBUILDABLE": "源地无法获得开工包所需建材，筹备已中止，托管物资已退回。",
		"PREPARING_ABORTED": "源分支人口已不足，开拓筹备中止。",
		"colonization_quote_expired": "报价已过期，请重新选择要派遣的家族。",
		"colonization_quote_corrupt": "报价数据已失效，请重新打开开拓面板。",
		"colonization_quote_forbidden": "报价不属于玩家国家。",
		"colonization_command_invalid": "开拓命令参数不完整。",
		"colonization_country_snapshot_unavailable": "国家快照尚未就绪，请稍后再试。",
		"colonization_country_invalid": "玩家国家句柄无效。",
		"family_colonization_unavailable": "开拓报价接口尚未就绪。",
		"colonization_family_cell_capacity": "目标地块的家族数量已达上限。",
		"economy_busy_retry": "经济正在结算。派遣已可排队，提交完成后自动出发。",
		"colonization_queued": "派遣已排队，将在经济结算完成后出发。",
		"colonization_cancel_queued": "取消已排队，将在经济结算完成后执行。",
		"colonization_started": "开拓队已经出发。",
		"economy_paused": "经济已因守恒失败暂停，无法派遣。",
		"economy_not_available": "经济运行时尚未就绪。",
		"colonization_topology_not_ready": "地图通行数据尚未就绪。",
		"colonization_visibility_unavailable": "当前视野数据不可用。",
		"colonization_expedition_invalid": "开拓队已结束或句柄已过期。",
	}.get(code, "当前无法执行开拓。")


static func _procurement_reason_text(reason: String) -> String:
	if reason.find("cash_insufficient") >= 0:
		return "国库现金不足"
	if reason.find("stock_insufficient") >= 0 or reason.find("goods_insufficient") >= 0 \
			or reason.find("stock_drift") >= 0:
		return "源地库存在成交前已被消耗"
	if reason.find("gate_closed") >= 0:
		return "国家资产通道未开放"
	if reason.find("merchant_missing") >= 0:
		return "源地没有可收款的商人"
	return reason
