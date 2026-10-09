extends RefCounted
class_name InfoPanelController

## Phase 0.4 / dots-full-migration §G.3 — main.gd 拆分推荐顺序第 1 步。
##
## 从 main.gd 抽出 ~340 行右侧地块信息面板逻辑：5 个 refresh_* 入口 +
## 1 个 ensure_emergent_labels 懒加载 + 5 个文字档位 helper（_vitality_band /
## _elevation_band / _climate_zone_name / _temperature_band / _moisture_band）。
##
## ─── 边界 ─────────────────────────────────────────────────────────────
## - 持有 14 个 @onready Label / Panel 静态引用（由 main.gd `_ready` 时一次性
##   注入 bind() Dictionary）；
## - 持有 5 个 emergent_* Label（懒创建，首次 refresh_emergent_lines 时挂到
##   _history_label 父节点末尾）；
## - 动态上下文（_selected_cell / _view_adapter / _current_map / _world_clock /
##   _generator / _sea_level / _hex_size）由 main.gd 通过 setter 推送；
## - 不直接读 main.gd 任何私有字段，保证可独立测试。
##
## ─── 调用面 ─────────────────────────────────────────────────────────
## main.gd 的 6 个 forwarder：
##   _refresh_info_panel  → controller.refresh_info_panel()
##   _refresh_weather_line → controller.refresh_weather_line()
##   _refresh_climate_line → controller.refresh_climate_line()
##   _refresh_vitality_line → controller.refresh_vitality_line()
##   _refresh_emergent_lines → controller.refresh_emergent_lines()
##   _ensure_emergent_labels → controller.ensure_emergent_labels()
##
## main.gd 必须在状态变化时同步调用以下 setter：
##   - _select_cell(cell)        → set_selected_cell(cell)
##   - _rebuild_view_adapter()   → set_view_adapter(new_adapter)
##   - _generate_and_render(...) → set_current_map / set_generator / set_sea_level
##   - world_clock 注入时        → set_world_clock(wc)

# ─── 静态引用（_ready 一次性注入） ───────────────────────────────────
var _right_panel: PanelContainer = null
var _pos_label: Label = null
var _elev_label: Label = null
var _climate_zone_label: Label = null
var _temp_label: Label = null
var _moist_label: Label = null
var _precip_label: Label = null
var _landform_label: Label = null
var _vegetation_label: Label = null
var _vitality_label: Label = null
var _cover_label: Label = null
var _weather_label: Label = null
var _feature_label: Label = null
var _mobility_label: Label = null
var _history_label: Label = null

# ─── Emergent Climate Coupling：5 个懒创建 Label ─────────────────────
var _emergent_temp_label: Label = null
var _emergent_ice_label: Label = null
var _emergent_feedback_label: Label = null
var _emergent_sun_label: Label = null
var _emergent_month_label: Label = null

# Physical circulation debug lines. Lazy-created to avoid scene layout churn.
var _physical_ocean_label: Label = null
var _physical_wind_label: Label = null
var _physical_pressure_label: Label = null

# 自然资源储量行（economy.resources）。懒创建单行多列 Label，挂到右侧面板 VBox 末尾。
# 数据驱动：内容直接遍历 ResourceProfileRegistry，读 MapData 的 reserve / extra_change 数组，
# 新增一种资源 .tres 后无需改本面板即可显示。
var _resource_label: Label = null

# ─── 动态上下文 ─────────────────────────────────────────────────────
var _selected_cell: HexCell = null
var _view_adapter: DCViewAdapter = null
var _current_map: MapData = null
var _world_clock: WorldClock = null
var _generator = null  # MapGenerator（避免循环 preload）
var _sea_level: float = 0.42
var _hex_size: float = 22.0  # 当前未直接消费，预留 future 用


func _init(refs: Dictionary) -> void:
	# 期望 keys: right_panel, pos, elev, climate_zone, temp, moist, precip,
	#           landform, vegetation, vitality, cover, weather, feature,
	#           mobility, history
	_right_panel = refs.get("right_panel")
	_pos_label = refs.get("pos")
	_elev_label = refs.get("elev")
	_climate_zone_label = refs.get("climate_zone")
	_temp_label = refs.get("temp")
	_moist_label = refs.get("moist")
	_precip_label = refs.get("precip")
	_landform_label = refs.get("landform")
	_vegetation_label = refs.get("vegetation")
	_vitality_label = refs.get("vitality")
	_cover_label = refs.get("cover")
	_weather_label = refs.get("weather")
	_feature_label = refs.get("feature")
	_mobility_label = refs.get("mobility")
	_history_label = refs.get("history")


# ─── Context setters ────────────────────────────────────────────────

func set_selected_cell(c) -> void:
	_selected_cell = c


func set_view_adapter(a: DCViewAdapter) -> void:
	_view_adapter = a


func set_current_map(m: MapData) -> void:
	_current_map = m


func set_world_clock(wc: WorldClock) -> void:
	_world_clock = wc


func set_generator(g) -> void:
	_generator = g


func set_sea_level(s: float) -> void:
	_sea_level = s


func set_hex_size(h: float) -> void:
	_hex_size = h


# ─── 公共 refresh API（与 main.gd 旧 func 名 1:1 对齐，去掉前导下划线） ─

func refresh_info_panel() -> void:
	if _selected_cell == null or _right_panel == null or _current_map == null:
		return
	var cell := _selected_cell
	var cfg_h: int = max(_current_map.height, 1)

	# ── 位置（cube + offset）
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	_pos_label.text = "位置：cube(%d,%d,%d)  offset(col=%d,row=%d)" % [
		cell.q, cell.r, cell.s, off.x, off.y
	]

	# ── 海拔（归一化 + 陆上海拔比例 + 文字档位）
	# B.1：通过 ViewAdapter 读 schema-mirrored 字段（cell.elevation）
	var sea: float = _sea_level
	var elev: float = _view_adapter.get_elevation(cell.index) if _view_adapter != null else float(cell.elevation)
	var land_h: float = (elev - sea) / maxf(1.0 - sea, 0.001)
	_elev_label.text = "海拔：%.3f（%s）   陆上高度：%+.2f" % [
		elev, _elevation_band(elev, sea), land_h
	]

	# ── 纬度气候带（按纬度 |ny - 0.5| 推导；不是生物群系或植被类型）
	var ny: float = float(off.y) / float(cfg_h - 1) if cfg_h > 1 else 0.5
	var anomaly: float = _world_clock.climate_anomaly if _world_clock != null else 0.0
	_climate_zone_label.text = "纬度气候带：%s（纬度 %.2f）   气候异常：%+.2f" % [
		_climate_zone_name(ny), ny, anomaly
	]

	# ── 当前温度 / 湿度 / 降水（B.1：走 ViewAdapter）
	var cs: Dictionary = cell.current_state
	var idx: int = int(cell.index)
	var ad: DCViewAdapter = _view_adapter
	var fallback_season: int = _world_clock.season_index() if _world_clock != null else 1
	var season: int = int(cs.get("season", fallback_season))
	var temp: float = ad.get_temp(idx) if ad != null else float(cell.temperature)
	_temp_label.text = "当前温度：%.2f（%s）" % [temp, _temperature_band(temp)]

	var moist: float = ad.get_moisture(idx) if ad != null else float(cell.moisture)
	var base_moist: float = ad.get_base_moisture(idx) if ad != null else float(cell.base_moisture)
	_moist_label.text = "当前湿度：%.2f（%s）   年均基线：%.2f" % [
		moist, _moisture_band(moist), base_moist
	]

	var wf := _weather_field_snapshot(cell, idx, ad)
	_precip_label.text = "当前降水：%.2f（水汽 %.2f / 云 %.2f）" % [
		float(wf["precip"]), float(wf["vapor"]), float(wf["cloud"])
	]

	# ── 三条独立轴（地貌 / 当前植被 / 地表覆盖）
	# B.1：landform / vegetation / cover / snow_cover 走 ViewAdapter（schema-mirrored）；
	# base_vegetation / vegetation_history 仍直读 cell（HexCell-only 无 SoA 对位）。
	var landform_v: int = ad.get_landform(idx) if ad != null else int(cell.landform)
	_landform_label.text = "地貌：%s" % LandformType.name_cn(landform_v)
	var vegetation_v: int = ad.get_vegetation(idx) if ad != null else int(cell.vegetation)
	var veg_now := VegetationType.name_cn(vegetation_v)
	if vegetation_v != cell.base_vegetation:
		var veg_base := VegetationType.name_cn(cell.base_vegetation)
		_vegetation_label.text = "当前植被：%s   ⚠ 当季已演替（生态基线：%s）" % [veg_now, veg_base]
	else:
		_vegetation_label.text = "当前植被：%s" % veg_now
	# Milestone 4：植被生命值 + 演替倒计时
	refresh_vitality_line()
	var snow_v: float = ad.get_snow_cover(idx) if ad != null else float(cell.snow_cover)
	var cover_v: int = ad.get_cover(idx) if ad != null else int(cell.cover)
	var snow_pct: float = snow_v * 100.0
	if snow_pct > 1.0:
		_cover_label.text = "覆盖：%s（雪盖 %.0f%%）" % [CoverType.name_cn(cover_v), snow_pct]
	else:
		_cover_label.text = "覆盖：%s" % CoverType.name_cn(cover_v)

	# Milestone 3：天气（每"日"由 weather 子系统更新；CLEAR 时不显示强度）
	refresh_weather_line()

	# ── 地理特征（河流 / 火山 / 湖泊种子）—— 雪盖已迁到 CoverLabel 不再重复
	# B.1：has_river 走 ViewAdapter；has_volcano / is_lake_seed 无 SoA 对位仍直读 cell。
	var feats := PackedStringArray()
	if (ad.get_has_river(idx) if ad != null else cell.has_river): feats.append("河流")
	if cell.has_volcano: feats.append("火山")
	if cell.is_lake_seed: feats.append("湖泊种子")
	_feature_label.text = "地理特征：%s" % ("无" if feats.is_empty() else ", ".join(feats))

	# ── 通行（基础通行 + 当季通行）
	# B.1：陆行能力来自 terrain profile；is_water 是物理水体语义，不能反推陆行。
	# passable_sea 与 is_passable_in_season 无 SoA 对位仍直读 cell。
	var terrain_v: int = ad.get_terrain(idx) if ad != null else int(cell.terrain)
	var passable_land_v: bool = TerrainType.is_passable_land(terrain_v)
	_mobility_label.text = "通行：陆 %s / 海 %s   move_cost=%d   当季可通行：%s" % [
		"是" if passable_land_v else "否",
		"是" if cell.passable_sea else "否",
		TerrainType.get_move_cost(terrain_v),
		"是" if cell.is_passable_in_season(season) else "否",
	]

	# ── 近期植被演替（vegetation_history 环形缓冲，最近 8 季）
	# Milestone 1：换源到独立植被轴，粒度更细；空缓冲时回退到 biome_history
	var veg_history := cell.vegetation_history
	if not veg_history.is_empty():
		var names := PackedStringArray()
		for i in range(veg_history.size()):
			names.append(VegetationType.name_cn(int(veg_history[i])))
		_history_label.text = "近期植被：%s" % " → ".join(names)
	else:
		var bio_history := cell.biome_history
		if bio_history.is_empty():
			_history_label.text = "近期植被：尚无记录"
		else:
			var names2 := PackedStringArray()
			for i in range(bio_history.size()):
				names2.append(TerrainType.terrain_name_cn(int(bio_history[i])))
			_history_label.text = "近期气候区：%s（旧兼容记录）" % " → ".join(names2)

	# Emergent Climate Coupling：三行涌现耦合信息（温度分解 / 海冰覆盖度 / 反馈缓冲）
	refresh_physical_lines()
	refresh_emergent_lines()
	# 自然资源储量（economy.resources）
	refresh_resource_lines()


# Milestone 3：单独刷新天气行，避免每天 tick 时重画整面板
func refresh_weather_line() -> void:
	if _selected_cell == null or _weather_label == null:
		return
	# B.1：通过 ViewAdapter 读 weather schema-mirrored 字段
	var sel_idx: int = int(_selected_cell.index)
	var has_wf: bool = _view_adapter.get_weather_field_init(sel_idx) if _view_adapter != null else _selected_cell.weather_field_initialized
	var wt: int = (_view_adapter.get_weather_type(sel_idx) if _view_adapter != null else _selected_cell.weather_type) if has_wf else WeatherType.WT.CLEAR
	var wi: float = (_view_adapter.get_weather_intensity(sel_idx) if _view_adapter != null else _selected_cell.weather_intensity) if has_wf else 0.0
	if wt == WeatherType.WT.CLEAR or wi <= 0.05:
		_weather_label.text = "天气：晴朗"
	else:
		_weather_label.text = "天气：%s（强度 %.0f%%）" % [WeatherType.name_cn(wt), wi * 100.0]


# Daily climate/weather line：单独刷新"当前温度 / 当前湿度 / 当前降水"三行，
# 让玩家在选中地块时能逐日看到太阳-热力-天气场链条的渐进变化。
# 与 refresh_info_panel 中的同名读取保持一致。
func refresh_climate_line() -> void:
	if _selected_cell == null:
		return
	var cell := _selected_cell
	# B.1：通过 ViewAdapter 读 schema-mirrored 字段
	var idx: int = int(cell.index)
	var ad: DCViewAdapter = _view_adapter

	# ── 当前温度
	if _temp_label != null:
		var temp: float = ad.get_temp(idx) if ad != null else float(cell.temperature)
		_temp_label.text = "当前温度：%.2f（%s）" % [temp, _temperature_band(temp)]

	# ── 当前湿度
	if _moist_label != null:
		var moist: float = ad.get_moisture(idx) if ad != null else float(cell.moisture)
		var base_moist_2: float = ad.get_base_moisture(idx) if ad != null else float(cell.base_moisture)
		_moist_label.text = "当前湿度：%.2f（%s）   年均基线：%.2f" % [
			moist, _moisture_band(moist), base_moist_2
		]

	# ── 当前降水：读取 weather pass 写出的实时场值，不再用季节表估算。
	if _precip_label != null:
		var wf := _weather_field_snapshot(cell, idx, ad)
		_precip_label.text = "当前降水：%.2f（水汽 %.2f / 云 %.2f）" % [
			float(wf["precip"]), float(wf["vapor"]), float(wf["cloud"])
		]
	refresh_physical_lines()
	# 资源储量随气候同日推进，piggyback 日级刷新让选中地块实时可见。
	refresh_resource_lines()


func _weather_field_snapshot(cell: HexCell, idx: int, ad: DCViewAdapter) -> Dictionary:
	var has_wf: bool = ad.get_weather_field_init(idx) if ad != null else bool(cell.weather_field_initialized)
	var precip: float = ad.get_weather_precip(idx) if ad != null else float(cell.weather_precip)
	var vapor: float = ad.get_weather_vapor(idx) if ad != null else float(cell.weather_vapor)
	var cloud: float = ad.get_weather_cloud(idx) if ad != null else float(cell.weather_cloud)
	if not has_wf:
		precip = float(cell.current_state.get("weather_precip", precip))
		vapor = float(cell.current_state.get("weather_vapor", vapor))
		cloud = float(cell.current_state.get("weather_cloud", cloud))
	return {
		"precip": clampf(precip, 0.0, 1.0),
		"vapor": clampf(vapor, 0.0, 1.0),
		"cloud": clampf(cloud, 0.0, 1.0),
	}


# Milestone 4：单独刷新植被生命值行（与 weather 一样按"日"高频刷新）
func refresh_vitality_line() -> void:
	if _selected_cell == null or _vitality_label == null:
		return
	var cell := _selected_cell
	# B.1：landform 走 ViewAdapter
	var lf_v: int = _view_adapter.get_landform(cell.index) if _view_adapter != null else int(cell.landform)
	if LandformType.is_water(lf_v):
		_vitality_label.text = "生命值：—（水域无植被生命值）"
		return
	var v: float = cell.vegetation_vitality
	var band: String = _vitality_band(v)
	# 演替倒计时：哪边 streak 接近触发就提示倒计时
	var hint := ""
	if cell._vitality_low_streak > 0:
		var rem: int = (_generator._c().succession_degrade_days if _generator != null else 180) - cell._vitality_low_streak
		if rem <= 0:
			hint = "  ⚠ 即将退化"
		elif rem <= 30:
			hint = "  ⚠ 退化倒计时 %d 天" % rem
	elif cell._vitality_high_streak > 0:
		var rem2: int = (_generator._c().succession_upgrade_days if _generator != null else 360) - cell._vitality_high_streak
		if rem2 <= 0:
			hint = "  ✓ 即将升级"
		elif rem2 <= 45:
			hint = "  ✓ 升级倒计时 %d 天" % rem2
	_vitality_label.text = "生命值：%.0f%%（%s）%s" % [v * 100.0, band, hint]


# Emergent Climate Coupling：懒创建三行 UI 标签（首次选中 cell 时调用一次）
# 动态挂到右侧面板 VBox 末尾，避免修改 .tscn。
func ensure_emergent_labels() -> void:
	if _emergent_temp_label != null:
		return
	var vbox: Node = _history_label.get_parent() if _history_label != null else null
	if vbox == null:
		return
	_emergent_temp_label = Label.new()
	_emergent_temp_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_temp_label)
	_emergent_ice_label = Label.new()
	_emergent_ice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_ice_label)
	_emergent_feedback_label = Label.new()
	_emergent_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_feedback_label)
	# True Insolation-Driven：额外两行
	_emergent_sun_label = Label.new()
	_emergent_sun_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_sun_label)
	_emergent_month_label = Label.new()
	_emergent_month_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_month_label)


func ensure_physical_labels() -> void:
	if _physical_ocean_label != null:
		return
	var vbox: Node = _history_label.get_parent() if _history_label != null else null
	if vbox == null:
		return
	_physical_ocean_label = Label.new()
	_physical_ocean_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_physical_ocean_label)
	_physical_wind_label = Label.new()
	_physical_wind_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_physical_wind_label)
	_physical_pressure_label = Label.new()
	_physical_pressure_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_physical_pressure_label)


func refresh_physical_lines() -> void:
	if _selected_cell == null:
		return
	ensure_physical_labels()
	if _physical_ocean_label == null:
		return
	var cell := _selected_cell
	var idx: int = int(cell.index)
	var ad: DCViewAdapter = _view_adapter
	var is_water: bool = bool(cell.passable_sea)
	var ocean_current: Vector2 = ad.get_ocean_current(idx) if ad != null else cell.ocean_current
	var wind: Vector2 = ad.get_wind_vector(idx) if ad != null else cell.wind_vector
	var wind_speed: float = ad.get_wind_speed(idx) if ad != null else float(cell.wind_speed)
	if wind_speed <= 0.0001 and wind.length() > 0.0001:
		wind_speed = wind.length()
	var upwelling: float = ad.get_upwelling_strength(idx) if ad != null else float(cell.upwelling_strength)
	var slp: float = ad.get_slp(idx) if ad != null else float(cell.slp)
	var curl: float = ad.get_wind_stress_curl(idx) if ad != null else float(cell.wind_stress_curl)
	var psi: float = ad.get_ocean_psi(idx) if ad != null else float(cell.ocean_psi)
	var heat_transport: float = float(cell.temperature_transport_anomaly)
	var ocean_mag_text: String = _fmt3(ocean_current.length()) if is_water else "—"
	var up_text: String = _fmt_signed3(upwelling) if is_water else "—"
	var ocean_dir_text: String = _dir_degrees_text(ocean_current) if is_water else "—"
	var curl_text: String = _fmt_signed3(curl) if is_water else "—"
	var psi_text: String = _fmt_signed3(psi) if is_water else "—"
	_physical_ocean_label.text = "洋流：强度 %s  热输运 %s  上升流 %s" % [
		ocean_mag_text, _fmt_signed3(heat_transport), up_text
	]
	_physical_wind_label.text = "风场：风速 %s  风向 %s  洋流方向 %s" % [
		_fmt3(wind_speed), _dir_degrees_text(wind), ocean_dir_text
	]
	_physical_pressure_label.text = "压力/ψ：海平压力 %s  风应力旋度 %s  流函数 ψ %s" % [
		_fmt_signed3(slp), curl_text, psi_text
	]


# 自然资源储量：懒创建单个多行 Label（首次刷新时挂到右侧面板 VBox 末尾，避免改 .tscn）。
func ensure_resource_labels() -> void:
	if _resource_label != null:
		return
	var vbox: Node = _history_label.get_parent() if _history_label != null else null
	if vbox == null:
		return
	_resource_label = Label.new()
	_resource_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_resource_label)


# 刷新选中地块的自然资源储量行（与 weather/vitality 一样可按"日"高频刷新）。
# 数据驱动：遍历 ResourceProfileRegistry，逐资源读 MapData 的 reserve / extra_change 数组（由
# run_natural_resource_pass / GDScript fallback 每 tick flush 回 MapData）。
func refresh_resource_lines() -> void:
	if _selected_cell == null or _current_map == null:
		return
	ensure_resource_labels()
	if _resource_label == null:
		return
	ResourceProfileRegistry.ensure_loaded()
	var profiles: Array = ResourceProfileRegistry.ordered()
	if profiles.is_empty():
		_resource_label.text = "自然资源：（未配置资源类型）"
		return
	var idx: int = int(_selected_cell.index)
	var ad: DCViewAdapter = _view_adapter
	var lf_v: int = ad.get_landform(idx) if ad != null else int(_selected_cell.landform)
	var is_water: bool = LandformType.is_water(lf_v)
	var lines := PackedStringArray()
	lines.append("自然资源储量：")
	for p in profiles:
		var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
		if bool(p.land_only) and is_water:
			lines.append("  %s：—（水域不可用）" % name_cn)
			continue
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var reserve: float = 0.0
		if field != "":
			var arr: PackedFloat32Array = _current_map.get(field)
			if idx >= 0 and idx < arr.size():
				reserve = float(arr[idx])
		var extra_field: String = ResourceProfileRegistry.extra_change_map_field(p)
		var extra_change: float = 0.0
		if extra_field != "":
			var extra_arr: PackedFloat32Array = _current_map.get(extra_field)
			if idx >= 0 and idx < extra_arr.size():
				extra_change = float(extra_arr[idx])
		if absf(extra_change) > 0.000001:
			lines.append("  %s：储量 %.3f（额外变化 %+.3f）" % [name_cn, reserve, extra_change])
		else:
			lines.append("  %s：储量 %.3f" % [name_cn, reserve])
	_resource_label.text = "\n".join(lines)


# Emergent Climate Coupling：刷新三行"涌现耦合"信息：
#   行 1 陆地 cell 显示温度分解，水体 cell 显示海冰覆盖度；
#   行 2 显示 soil_moisture / vegetation_growth_pressure 两个反馈缓冲；
#   行 3 顶部"当前季节"名义 + 过渡百分比。
# 缺字段时一次 WARN 后静默（通过 get(key, fallback) 兜底）。
func refresh_emergent_lines() -> void:
	if _selected_cell == null:
		return
	ensure_emergent_labels()
	var cell := _selected_cell
	var _cs: Dictionary = cell.current_state

	# 行 1：陆地 → 温度分解；水体 → 海冰覆盖度
	# B.1：landform / sea_ice_fraction / temperature / temp_baseline 走 ViewAdapter
	var em_idx: int = int(cell.index)
	var em_ad: DCViewAdapter = _view_adapter
	if _emergent_temp_label != null:
		var em_lf: int = em_ad.get_landform(em_idx) if em_ad != null else int(cell.landform)
		if LandformType.is_water(em_lf):
			var ice_f: float = em_ad.get_sea_ice_frac(em_idx) if em_ad != null else float(cell.sea_ice_fraction)
			_emergent_temp_label.text = "海冰覆盖：%.1f%%" % [ice_f * 100.0]
		else:
			var t_eff: float = em_ad.get_temp(em_idx) if em_ad != null else float(cell.temperature)
			var t_base: float = em_ad.get_temp_baseline(em_idx) if em_ad != null else float(cell.temp_baseline)
			_emergent_temp_label.text = "温度分解：基线 %.2f  叠加 %+.2f（含反照率/岸泄/地形）" % [t_base, t_eff - t_base]

	# 行 2：土壤湿度反馈 / 植被生长压力（可能为 0）
	if _emergent_feedback_label != null:
		var sm: float = float(cell.get("soil_moisture"))
		var vp: float = float(cell.get("vegetation_growth_pressure"))
		_emergent_feedback_label.text = "反馈缓冲：土壤湿度 %+.3f  植被压力 %+.3f（本季累计）" % [sm, vp]

	# 行 3：日历日期。优先读 WorldClock，确保与顶部 HUD 同源。
	if _emergent_ice_label != null:
		if _world_clock != null and _world_clock.has_method("calendar_date"):
			var cal: Dictionary = _world_clock.calendar_date()
			_emergent_ice_label.text = "日历：%d 月 %d 日（全年第 %d/%d 天）" % [
				int(cal.month), int(cal.day_of_month), int(cal.day_of_year), int(cal.days_per_year)
			]
		elif _generator != null:
			var phase: float = _world_clock.season_phase() if _world_clock != null else 0.0
			var cal_fallback: Dictionary = _generator.month_of_year(phase)
			_emergent_ice_label.text = "日历：%d 月 %d 日（全年第 %d/%d 天）" % [
				int(cal_fallback.month), int(cal_fallback.day_of_month),
				int(cal_fallback.day_of_year), int(cal_fallback.get("days_per_year", 365))
			]
		else:
			_emergent_ice_label.text = "日历：—"

	# 行 4：太阳直射点 + 日射相对年均（True Insolation-Driven 因果链可视化）
	if _emergent_sun_label != null and _generator != null and _world_clock != null:
		var phase_sun: float = _world_clock.season_phase()
		var subsolar_rad: float = _generator._subsolar_lat_rad(phase_sun)
		var subsolar_deg: float = rad_to_deg(subsolar_rad)
		var ny_sun: float = _generator.cell_ny(cell)
		var dev_sun: float = _generator._insol_dev(ny_sun, phase_sun)
		_emergent_sun_label.text = "太阳：直射点 %+.1f°  日射距年均 %+.1f%%" % [subsolar_deg, dev_sun * 100.0]

	# 行 5：观测月份（本地温度 EMA 距年均）——赤道显示"常年温暖"
	if _emergent_month_label != null and _generator != null and _world_clock != null:
		var phase_m: float = _world_clock.season_phase()
		var obs: Dictionary = _generator.observe_local_month(cell, phase_m)
		var dev_v: float = float(obs.dev)
		var warmer = obs.warmer_than_annual
		var obs_txt: String
		if warmer == null:
			obs_txt = "常年温暖"
		elif bool(warmer):
			obs_txt = "当前偏暖 %+.2f" % [dev_v]
		else:
			obs_txt = "当前偏冷 %+.2f" % [dev_v]
		_emergent_month_label.text = "观测：%d 月 · %s（振幅 %.0f%%）" % [int(obs.calendar_month), obs_txt, float(obs.magnitude) * 100.0]


# ─── 文字档位 helper（仅 UI 用，不参与游戏逻辑） ─────────────────────

func _fmt3(v: float) -> String:
	return "%.3f" % v


func _fmt_signed3(v: float) -> String:
	return "%+.3f" % v


func _dir_degrees_text(v: Vector2) -> String:
	if v.length() < 0.0001:
		return "—"
	return "%.0f°" % fposmod(rad_to_deg(atan2(v.y, v.x)), 360.0)


func _vitality_band(v: float) -> String:
	if v < 0.15: return "濒死"
	if v < 0.40: return "枯萎"
	if v < 0.70: return "亚健康"
	if v < 0.90: return "健康"
	return "繁茂"


func _elevation_band(elev: float, sea: float) -> String:
	if elev < sea * 0.30: return "深海"
	if elev < sea * 0.85: return "近海"
	if elev < sea: return "浅海"
	var land := (elev - sea) / maxf(1.0 - sea, 0.001)
	if land < 0.05: return "海岸 / 海滩"
	if land < 0.30: return "低地平原"
	if land < 0.55: return "丘陵"
	if land < 0.80: return "山地"
	if land < 0.95: return "高峰"
	return "雪线以上"


func _climate_zone_name(ny: float) -> String:
	var d: float = absf(ny - 0.5)
	if d < 0.10: return "热带"
	if d < 0.20: return "副热带"
	if d < 0.32: return "温带"
	if d < 0.42: return "副极地"
	return "极地"


func _temperature_band(t: float) -> String:
	if t < 0.06: return "极寒"
	if t < 0.20: return "严寒"
	if t < 0.30: return "寒冷"
	if t < 0.40: return "凉爽"
	if t < 0.55: return "温和"
	if t < 0.75: return "温暖"
	if t < 0.90: return "炎热"
	return "酷热"


func _moisture_band(m: float) -> String:
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
