extends RefCounted
class_name CellBoardViewModel

## 悬停地块时左侧展板的唯一数据来源：物资行情 + 阶层人口。
##
## 只读已发布快照，不写模拟、不碰检查器的历史缓存。
## 两张表都不描述「这一行为什么被选中」——展板只列出当地市场与当地人口里
## 最有代表性的几项，排名依据留在代码里，不往玩家脸上写说明文字。
##
## 成本约束（原生 read-view）：每次新键要等一个提交边界，未就绪时返回
## ok=false / busy=true。调用方按 pending 处理并稍后重试，绝不拿旧值冒充当日。

const GOODS_SCALE := 1000.0
const MONEY_SCALE := 10000.0
const Q16 := 65536.0

const MARKET_TOP_N := 5
const COHORT_TOP_N := 5
const CACHE_LIMIT := 96
const CACHE_DROP := 24
const EPSILON := 0.000001

## 影响力口径与 IdeologyProfile 的默认权重同源：
## opinion_owner_influence_weight = 2、opinion_funds_per_influence = 1000000。
## 一致性由 set_influence_weights() 在拿到理念配置时覆盖。
const DEFAULT_OWNER_INFLUENCE_WEIGHT := 2
const DEFAULT_FUNDS_PER_INFLUENCE := 1000000

var _map: MapData
## 经济门面按需解析：展板可能在玩家国家与经济运行时绑定之前就配置好，
## 抓一次对象快照会在首帧之后永久读到 null。
var _economy_provider: Callable
var _economy = null
var _inspector: CellInspectorViewModel
var _world_clock: WorldClock
var _owner_weight := DEFAULT_OWNER_INFLUENCE_WEIGHT
var _funds_per_influence := DEFAULT_FUNDS_PER_INFLUENCE

## cache_key = "cell:day"。市场与人口都按提交边界推进，但悬停卡与检查器
## 同样以日为单位失效；共用日键可以避免两套时间线互相打脸。
var _cache: Dictionary = {}
var _cache_order: Array = []
var _stats := {"builds": 0, "hits": 0, "pending": 0}


func set_context(map: MapData, economy_provider: Callable,
		inspector: CellInspectorViewModel, world_clock: WorldClock) -> void:
	_map = map
	_economy_provider = economy_provider
	_economy = null
	_inspector = inspector
	_world_clock = world_clock
	_cache.clear()
	_cache_order.clear()
	_stats = {"builds": 0, "hits": 0, "pending": 0}
	ResourceProfileRegistry.ensure_loaded()
	GoodProfileRegistry.ensure_loaded()


## 理念配置里的影响力权重是这份排名口径的上游；取不到时沿用默认值。
func set_influence_weights(owner_weight: int, funds_per_influence: int) -> void:
	_owner_weight = maxi(owner_weight, 0)
	_funds_per_influence = maxi(funds_per_influence, 1)
	_cache.clear()
	_cache_order.clear()


func debug_stats() -> Dictionary:
	return {
		"entries": _cache.size(),
		"builds": int(_stats["builds"]),
		"hits": int(_stats["hits"]),
		"pending": int(_stats["pending"]),
	}


## 返回 {"ok": true, "market": {...}, "cohorts": {...}}，
## 或 {"ok": false, "pending": true}（原生尚未就绪 / 该格无数据）。
func build(cell_index: int) -> Dictionary:
	if _map == null or cell_index < 0:
		return {"ok": false, "reason": "no_context"}
	_economy = _economy_provider.call() if _economy_provider.is_valid() else null
	if _economy == null:
		return {"ok": false, "reason": "no_context"}
	var day := _day()
	var key := "%d:%d" % [cell_index, day]
	var cached: Dictionary = _cache.get(key, {})
	if not cached.is_empty():
		_stats["hits"] = int(_stats["hits"]) + 1
		return cached

	var population: Dictionary = _economy.population_cell_snapshot(cell_index, false)
	var population_day := int(population.get("read_view_day", day))
	var day_ready := population_day >= day or (day == 0 and population_day == -1)
	var population_ready := bool(population.get("ok", false)) \
		and population.has("populations") and day_ready
	if not population_ready:
		# 已知有人定居的格子在首次订阅人口时一并订阅市场与组织度，
		# 让后台在同一次 read-view 刷新里把三份快照备齐，省掉一轮串行重试。
		if _is_settled_hint(cell_index):
			_economy.market_cell_snapshot(cell_index)
			if _economy.has_method("cell_mobilization_snapshot"):
				_economy.cell_mobilization_snapshot(cell_index)
		return _pending_payload(population, not day_ready)
	var population_total := int(population.get("population", 0))
	if population_total <= 0:
		for raw in population.get("populations", PackedInt64Array()):
			population_total += maxi(int(raw), 0)
	# 无人区没有市场：不把一张全零的表摆给玩家看，也不白白占一个 read-view 订阅。
	var settled := population_total > 0
	var market: Dictionary = {}
	var mobilization: Dictionary = {}
	if settled:
		market = _economy.market_cell_snapshot(cell_index)
		if _economy.has_method("cell_mobilization_snapshot"):
			mobilization = _economy.cell_mobilization_snapshot(cell_index)
		var market_day := int(market.get("read_view_day", population_day))
		if not bool(market.get("ok", false)) or not market.has("good_ids") \
				or market_day != population_day:
			return _pending_payload(market, market_day != population_day)
		var mobilization_stale := bool(mobilization.get("ok", false)) \
			and int(mobilization.get("read_view_day", population_day)) != population_day
		if mobilization_stale or _snapshot_pending(mobilization):
			return _pending_payload(mobilization, mobilization_stale)

	var payload := {
		"ok": true,
		"cell_index": cell_index,
		"day": day,
		"settled": settled,
		"population": population_total,
		"market": _market_block(market),
		"cohorts": _cohort_block(_cohort_rows(population, mobilization)),
	}
	_stats["builds"] = int(_stats["builds"]) + 1
	_store(key, payload)
	return payload


func _pending_payload(snapshot: Dictionary, stale: bool) -> Dictionary:
	var pending := stale or _snapshot_pending(snapshot)
	if pending:
		_stats["pending"] = int(_stats["pending"]) + 1
	return {"ok": false, "pending": pending}


func _snapshot_pending(snapshot: Dictionary) -> bool:
	return bool(snapshot.get("busy", false)) or bool(snapshot.get("read_view_pending", false))


func _is_settled_hint(cell_index: int) -> bool:
	if _inspector == null:
		return false
	return int(_inspector.population_summary(cell_index).get("population", 0)) > 0


# ───────────────────────────── 物资行情 ─────────────────────────────

## 五类代表物资：需求最大、本地供给最大、价格最高、价格最低、缺口最大。
## 每个角色都在「还没被选走的物资」里挑，所以同一物资只出现一次；某个角色
## 挑不出来（例如本地没有供给）就少一行，不拿次优物资凑数冒充。
func _market_block(snapshot: Dictionary) -> Dictionary:
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if good_ids.is_empty():
		return {"rows": [], "count": 0, "stock_scale": ""}
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var price: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	var demand_ema: PackedInt64Array = snapshot.get("demand_ema", PackedInt64Array())
	var business_ema: PackedInt64Array = snapshot.get(
		"business_demand_ema", PackedInt64Array())
	var supply_ema: PackedInt64Array = snapshot.get(
		"offered_supply_ema", PackedInt64Array())
	var anchor_price: PackedInt32Array = snapshot.get(
		"cost_anchor_price", PackedInt32Array())
	var technology: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var count := good_ids.size()
	var enforce_technology := technology.size() == count

	# 一次扫描把需要的列换成展示量纲；之后每个角色各扫一遍（172 个物资本身就很便宜）。
	var stock_units := PackedFloat64Array()
	var demand_units := PackedFloat64Array()
	var supply_units := PackedFloat64Array()
	var price_value := PackedFloat64Array()
	stock_units.resize(count)
	demand_units.resize(count)
	supply_units.resize(count)
	price_value.resize(count)
	for i in range(count):
		var raw_price := int(price[i]) if i < price.size() else 0
		var eligible := raw_price > 0 and (not enforce_technology or technology[i] != 0)
		stock_units[i] = float(stock[i]) / GOODS_SCALE if i < stock.size() else 0.0
		demand_units[i] = (float(demand_ema[i]) / GOODS_SCALE
			if i < demand_ema.size() else 0.0) \
			+ (float(business_ema[i]) / GOODS_SCALE if i < business_ema.size() else 0.0)
		supply_units[i] = float(supply_ema[i]) / GOODS_SCALE \
			if i < supply_ema.size() else 0.0
		# 价格非正的物资在本地还没有价格，任何角色都不该选中它。
		price_value[i] = float(raw_price) / MONEY_SCALE if eligible else 0.0

	var picked: Array[int] = []
	var roles: Array[String] = []
	for role in ["demand", "supply", "price_high", "price_low", "gap"]:
		var best := -1
		var best_value := 0.0
		for i in range(count):
			if price_value[i] <= 0.0 or picked.has(i):
				continue
			var value := 0.0
			var valid := true
			match role:
				"demand":
					value = demand_units[i]
					valid = value > EPSILON
				"supply":
					value = supply_units[i]
					valid = value > EPSILON
				"price_high":
					value = price_value[i]
				"price_low":
					# 最低价只在该物资确实在本地流通过时才有意义。
					value = price_value[i]
					valid = stock_units[i] > EPSILON or demand_units[i] > EPSILON
				"gap":
					value = demand_units[i] - supply_units[i]
					valid = value > EPSILON and demand_units[i] > EPSILON
			if not valid:
				continue
			var better := best < 0 \
				or (value < best_value if role == "price_low" else value > best_value)
			if better:
				best = i
				best_value = value
		if best >= 0:
			picked.append(best)
			roles.append(String(role))
		if picked.size() >= MARKET_TOP_N:
			break
	if picked.is_empty():
		return {"rows": [], "count": 0, "stock_scale": ""}

	var max_stock := 0.0
	for index in picked:
		max_stock = maxf(max_stock, stock_units[index])
	var rows: Array = []
	for cursor in range(picked.size()):
		var index := picked[cursor]
		var stable_id := String(good_ids[index])
		var raw_price := int(price[index]) if index < price.size() else 0
		var anchor_raw := int(anchor_price[index]) if index < anchor_price.size() else 0
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name := String(profile.display_name) if profile != null \
			and String(profile.display_name) != "" else stable_id
		var price_index := float(raw_price) / float(anchor_raw) if anchor_raw > 0 else 1.0
		rows.append({
			"role": roles[cursor],
			"id": stable_id,
			"name": display_name,
			"icon": String(GoodProfileRegistry.icon_key(stable_id)),
			"stock_units": stock_units[index],
			"stock_text": UITokens.format_compact_number_cn(stock_units[index], 2),
			# 五行同屏共享一条量程：本轮最大储备做满格。
			"stock_ratio": clampf(stock_units[index] / max_stock, 0.0, 1.0) \
				if max_stock > EPSILON else 0.0,
			"price": price_value[index],
			"price_text": _money_text(raw_price),
			"price_index": price_index,
			"price_accent": _price_accent(price_index),
			"demand_units": demand_units[index],
			"supply_units": supply_units[index],
		})
	var scale := "0–%s" % UITokens.format_compact_number_cn(max_stock, 3) if max_stock > EPSILON else ""
	return {"rows": rows, "count": rows.size(), "stock_scale": scale}


## 价格相对成本锚的冷暖：贵 = 朱红，便宜 = 铜绿。颜色代替「偏高/偏低」的文字。
func _price_accent(price_index: float) -> Color:
	if price_index >= 1.5:
		return UITokens.DOSSIER_OXBLOOD
	if price_index >= 1.15:
		return UITokens.DOSSIER_BRASS
	if price_index <= 0.75:
		return UITokens.DOSSIER_VERDIGRIS
	return UITokens.DOSSIER_INK_MUTED


# ───────────────────────────── 阶层人口 ─────────────────────────────

## 按当地影响力取前五：人口 + 有产就业 × 权重 + 存款 / 影响力价。
## 组织度按职业读取（原生只对职业聚合），同一职业的多个 cohort 共用一个值。
func _cohort_rows(snapshot: Dictionary, mobilization: Dictionary) -> Array:
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	if populations.is_empty():
		return []
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var funds: PackedInt64Array = snapshot.get("funds_by_cohort", PackedInt64Array())
	var income: PackedInt64Array = snapshot.get("epoch_income_by_cohort", PackedInt64Array())
	var owner_employed: PackedInt64Array = snapshot.get(
		"owner_employed_by_cohort", PackedInt64Array())
	var satisfaction: PackedInt32Array = snapshot.get(
		"overall_satisfaction_by_cohort_q16", PackedInt32Array())
	if satisfaction.is_empty():
		satisfaction = snapshot.get("satisfaction_by_cohort_q16", PackedInt32Array())
	var living_levels: PackedInt32Array = snapshot.get(
		"living_standard_level_by_cohort", PackedInt32Array())
	var profession_indices: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var profession_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var profession_names: PackedStringArray = snapshot.get(
		"profession_display_names", PackedStringArray())
	var ethnicity_indices: PackedInt32Array = snapshot.get("ethnicity_ids", PackedInt32Array())
	var organization := _organization_by_profession(mobilization)

	var influences := PackedFloat64Array()
	influences.resize(populations.size())
	var total_influence := 0.0
	for i in range(populations.size()):
		var people := maxi(int(populations[i]), 0)
		var owners := int(owner_employed[i]) if i < owner_employed.size() else 0
		var cash := int(funds[i]) if i < funds.size() else 0
		var influence := float(people) \
			+ float(maxi(owners, 0) * _owner_weight) \
			+ float(maxi(cash, 0)) / float(_funds_per_influence)
		influences[i] = influence
		total_influence += influence
	# 当地影响力为零（空表 / 全部无人口）时不出表，避免摆一排 0%。
	if total_influence <= EPSILON:
		return []

	var order: Array[int] = []
	for i in range(populations.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		if not is_equal_approx(influences[a], influences[b]):
			return influences[a] > influences[b]
		if int(populations[a]) != int(populations[b]):
			return int(populations[a]) > int(populations[b])
		return a < b)
	if order.size() > COHORT_TOP_N:
		order = order.slice(0, COHORT_TOP_N)

	var ethnicity_count := 0
	for i in range(ethnicity_indices.size()):
		if int(ethnicity_indices[i]) >= ethnicity_count:
			ethnicity_count = int(ethnicity_indices[i]) + 1
	var rows: Array = []
	for i in order:
		var profession_index := int(profession_indices[i]) \
			if i < profession_indices.size() else -1
		var stable_id := String(profession_ids[profession_index]) \
			if profession_index >= 0 and profession_index < profession_ids.size() else ""
		var display_name := String(profession_names[profession_index]) \
			if profession_index >= 0 and profession_index < profession_names.size() else ""
		if display_name.is_empty():
			display_name = stable_id if not stable_id.is_empty() else "阶层"
		var people := maxi(int(populations[i]), 0)
		var sat := 0.0
		if i < satisfaction.size() and satisfaction[i] >= 0:
			sat = clampf(float(satisfaction[i]) / Q16, 0.0, 1.0)
		var living_level := int(living_levels[i]) if i < living_levels.size() else -1
		var org = organization.get(profession_index, null)
		var income_raw := int(income[i]) if i < income.size() else 0
		# 展板按阶层人口展示可比较的人均口径，避免大阶层仅因人数多而
		# 看起来存款和收入更高。金额仍以原生子单位保存，先在人均后格式化。
		var funds_per_capita := int(funds[i]) / people if i < funds.size() and people > 0 else 0
		var income_per_capita := income_raw / people if people > 0 else 0
		var share := influences[i] / total_influence
		rows.append({
			"id": int(handles[i]) if i < handles.size() else i,
			"name": display_name,
			"icon": String(IconCatalog.profession_semantic(stable_id)) \
				if not stable_id.is_empty() else "population.crowd",
			"population": people,
			"population_text": UITokens.format_compact_number_cn(float(people), 1),
			"share": clampf(share, 0.0, 1.0),
			"funds_text": _money_text(funds_per_capita),
			"income_text": _signed_money_text(income_per_capita),
			"income_positive": income_per_capita >= 0,
			"living_level": living_level,
			# 生活水平的词、图标、颜色统一取自地块档案的同一份口径，
			# 免得展板与档案对同一个阶层说出两种生活水平。
			"living_name": _inspector._living_standard_name(living_level) \
				if living_level >= 0 else "",
			"living_icon": _inspector._living_standard_icon(living_level) \
				if living_level >= 0 else "history",
			"living_accent": _inspector._living_standard_accent(living_level) \
				if living_level >= 0 else UITokens.DOSSIER_INK_MUTED,
			"satisfaction": sat,
			"satisfaction_text": "%d%%" % int(round(sat * 100.0)),
			"satisfaction_accent": _satisfaction_accent(sat),
			"organization": float(org.get("organization", -1.0)) if org != null else -1.0,
			"organization_text": String(org.get("organization_text", "")) if org != null else "",
			"organization_stage": int(org.get("stage", 0)) if org != null else 0,
			"organization_accent": org.get("accent", UITokens.ACCENT) if org != null \
				else UITokens.ACCENT,
			"ethnicity_pending": ethnicity_count > 1,
		})
	return rows


## 组织度只对职业聚合（原生约定：没有异动的职业不单列一行），
## 因此读不到就是「无组织读数」，整段不渲染，不伪造 0。
func _organization_by_profession(snapshot: Dictionary) -> Dictionary:
	var out := {}
	if not bool(snapshot.get("ok", false)):
		return out
	for raw in snapshot.get("rows", []):
		var row: Dictionary = raw
		var profession := int(row.get("profession", -1))
		if profession < 0:
			continue
		var stage := clampi(int(row.get("stage", 0)), 0, 4)
		var existing = out.get(profession, null)
		if existing != null and int((existing as Dictionary).get("stage", 0)) > stage:
			continue
		var org := clampf(float(clampi(int(row.get("mobilization_q16", 0)), 0, 65536))
			/ Q16, 0.0, 1.0)
		out[profession] = {
			"stage": stage,
			"organization": org,
			"organization_text": "%d%%" % int(round(org * 100.0)),
			"accent": _stage_accent(stage),
		}
	return out


func _cohort_block(rows: Array) -> Dictionary:
	return {"rows": rows, "count": rows.size()}


# ───────────────────────────── 展示换算 ─────────────────────────────

func _money_text(subunits: int) -> String:
	if subunits != 0 and absi(subunits) < 100:
		return "%.4f" % (float(subunits) / MONEY_SCALE)
	return UITokens.format_compact_number_cn(float(subunits) / MONEY_SCALE, 2)


func _signed_money_text(subunits: int) -> String:
	var body := _money_text(absi(subunits))
	return ("+" if subunits >= 0 else "-") + body


func _satisfaction_accent(value: float) -> Color:
	if value < 0.22:
		return UITokens.RISK
	if value < 0.45:
		return UITokens.WARN
	if value < 0.72:
		return UITokens.GOOD
	return UITokens.RESOURCE


func _stage_accent(stage: int) -> Color:
	if stage >= 3:
		return UITokens.RISK
	if stage >= 1:
		return UITokens.WARN
	return UITokens.ACCENT


# ───────────────────────────── 缓存 ─────────────────────────────

func current_day() -> int:
	return _day()


func _day() -> int:
	var frame := MapDrawnFrame.for_map(_map)
	if frame != null:
		return frame.received_day
	if _inspector != null:
		return _inspector.sample_day()
	if _world_clock != null:
		return _world_clock.day_index()
	return 0


func _store(key: String, payload: Dictionary) -> void:
	if _cache.size() >= CACHE_LIMIT:
		var drop := _cache_order.slice(0, CACHE_DROP)
		_cache_order = _cache_order.slice(drop.size(), _cache_order.size())
		for stale in drop:
			_cache.erase(stale)
	_cache[key] = payload
	_cache_order.append(key)
