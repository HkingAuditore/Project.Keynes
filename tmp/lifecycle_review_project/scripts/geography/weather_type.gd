# weather_type.gd
# Milestone 3：天气事件枚举（局地、临时、按 day_changed 推进）。
#
# 与 LandformType / VegetationType / CoverType 完全正交，仅作用于 cell.current_state，
# 不写回 base_*；季节切换时 weather 会自然延续/迁移，年度漂移（Phase 8）不受影响。
#
# 现实对照与游戏意义：
#   CLEAR    — 晴朗，无影响（current_state.weather 默认值）
#   RAIN     — 普通雨带，+moisture，可能形成 FLOODING（低洼陆地）
#   STORM    — 雷暴，强 +moisture，温度小幅下降，可形成 FLOODING
#   BLIZZARD — 暴风雪，温度大幅下降，强制 SNOW 覆盖物，可阻断陆上通行
#   DROUGHT  — 旱灾，强 -moisture，温度上升，长期持续会触发 Phase 8 base_moisture 下漂
#   FOG      — 雾，几乎不影响数值，主要是视觉效果（影响视野，未来玩法用）
#   HEATWAVE — 热浪，温度大幅上升，-moisture，加速 SNOW/SEA_ICE 融化
#   MONSOON  — 兼容枚举名：强热带暴雨，STORM 加强版；由温度/水汽/云/降水/不稳定度判定
#
# v-data-driven：所有数值与视觉参数已迁出到 WeatherProfile (.tres)。
# 本文件现在是一个薄 Facade：保留枚举与静态查询签名，实现转发到 WeatherProfileRegistry。
# 调用方（WeatherSystem、UI 面板）无需修改。

class_name WeatherType

enum WT {
	CLEAR,
	RAIN,
	STORM,
	BLIZZARD,
	DROUGHT,
	FOG,
	HEATWAVE,
	MONSOON,
}

# --- 静态查询（全部转发到 WeatherProfileRegistry） -----------------------

static func name_cn(w: WT) -> String:
	var p := WeatherProfileRegistry.get_profile(int(w))
	if p == null:
		return str(w)
	return p.display_name

static func moisture_delta(w: WT) -> float:
	var p := WeatherProfileRegistry.get_profile(int(w))
	if p == null:
		return 0.0
	return p.moisture_delta

static func temp_delta(w: WT) -> float:
	var p := WeatherProfileRegistry.get_profile(int(w))
	if p == null:
		return 0.0
	return p.temp_delta

static func can_form_snow(w: WT) -> bool:
	var p := WeatherProfileRegistry.get_profile(int(w))
	if p == null:
		return false
	return p.can_form_snow

static func can_form_flood(w: WT) -> bool:
	var p := WeatherProfileRegistry.get_profile(int(w))
	if p == null:
		return false
	return p.can_form_flood
