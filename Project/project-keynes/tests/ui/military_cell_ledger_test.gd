extends SceneTree

## 地块档案「军事」页的契约测试（headless）：
##
##   1) CellInspectorViewModel 只产出一块 `military_cell`，三行官营建筑顺序固定，
##      旧的 metrics / gauges / military_context / 解释性 insight 都不再出现；
##   2) 科技闸门：没研究对应科技的城防行没有按钮、target = -1；研究后按钮指向
##      已解锁的最高档目录下标（dense index，不是角色名）；
##   3) 现存档位与座数、在建工程、训练进度、部队名录都由快照如实折算；
##   4) 组件与面板：三行节点恒定，同一模型重复补丁不增删节点，按下按钮发出
##      {cell, role, op, building:int}。
##
##   godot --headless --path Project/project-keynes \
##     -s res://tests/ui/military_cell_ledger_test.gd

const CELL := 42
const PLAYER_HANDLE := 0x100000001
const VIEW_MODEL_SCRIPT := preload("res://scripts/ui/cell_inspector_view_model.gd")
const LEDGER_SCENE := preload("res://scenes/ui/military_cell_ledger.tscn")
const PANEL_SCENE := preload("res://scenes/ui/inspector_panel.tscn")

var _failures := PackedStringArray()


class FakeCountryFacade:
	var owned := true
	var handle := 0x100000001
	var techs := PackedStringArray()

	func cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "owned": owned, "country_handle": handle,
			"country_name": "测试国"}

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "technology_ids": techs}

	## 国库：默认现金与建材都充足，这样既有「可建造」断言不会被缺料改写；
	## 缺料分支由 `treasury_empty` 单独构造。
	var treasury_empty := false

	func treasury_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "cash": 100000000000,
			"good_ids": PackedStringArray(["logs"]),
			"quantities": PackedInt64Array([0 if treasury_empty else 1000000000])}


class FakeMilitaryFacade:
	var catalog_data: Dictionary = {}
	var snapshot_data: Dictionary = {}

	func catalog() -> Dictionary:
		return catalog_data

	func cell_snapshot(_cell: int, _observer: int) -> Dictionary:
		return snapshot_data

	## 与真实门面同形：把 dense 的 material_goods / material_qty 还原成
	## `{good_id, qty}`。测试目录用下标 0 指代木材；其余下标映射到不同物资，
	## 这样多建材用例能验证「逐项列全」而不是四个同名条目。
	const TEST_GOODS := ["logs", "turf_block", "raw_stone", "bricks"]

	func state_building_materials(building_index: int) -> Array:
		var rows: Array = catalog_data.get("state_buildings", [])
		if building_index < 0 or building_index >= rows.size():
			return []
		var row: Dictionary = rows[building_index]
		var ids: PackedInt32Array = row.get("material_goods", PackedInt32Array())
		var quantities: PackedInt64Array = row.get("material_qty", PackedInt64Array())
		var out: Array = []
		for index in range(ids.size()):
			var good_index := int(ids[index])
			out.append({"good_id": TEST_GOODS[good_index % TEST_GOODS.size()],
				"qty": int(quantities[index]) if index < quantities.size() else 0})
		return out


class FakeGenerator:
	var military = null
	var country = null

	func get_military_facade():
		return military

	func get_country_facade():
		return country

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 42}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_read_model()
	_test_tech_gate()
	_test_cost_blocking()
	_test_upgrade_describes_target_tier()
	_test_upkeep_totals()
	_test_upkeep_after_rebuild()
	_test_upkeep_after_upgrade()
	_test_upkeep_single_stack_is_quiet()
	_test_cost_detail_matches_tooltip()
	_test_cost_without_materials()
	_test_construction_and_flags()
	await _test_ledger_component()
	await _test_panel_integration()
	if _failures.is_empty():
		print("[military-cell-test] OK")
	else:
		for failure in _failures:
			printerr("[military-cell-test] FAIL: %s" % failure)
		printerr("[military-cell-test] %d failure(s)" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


# ---------------------------------------------------------------- fixtures

func _catalog() -> Dictionary:
	return {
		"units": [
			{"id": "militia", "name": "民兵", "class": 0},
			{"id": "spearmen", "name": "长枪兵", "class": 0},
		],
		"state_buildings": [
			{"id": "warrior_lodge", "name": "战士营地", "role": 0, "tier": 1,
				"unlock_tech_id": "", "capacity": 4, "fort_bonus": 0.0,
				"training_speed": 1.0, "upkeep": 0.02, "build_days": 10,
				"material_goods": PackedInt32Array([0]), "material_qty": PackedInt64Array([20000])},
			{"id": "garrison_barracks", "name": "戍卫营", "role": 0, "tier": 3,
				"unlock_tech_id": "tech.military.standing_army", "capacity": 25,
				"fort_bonus": 0.0, "training_speed": 1.0, "upkeep": 0.15,
				"build_days": 30,
				"material_goods": PackedInt32Array([0]), "material_qty": PackedInt64Array([40000])},
			{"id": "earthen_rampart", "name": "夯土城垣", "role": 1, "tier": 1,
				"unlock_tech_id": "tech.military.earthen_ramparts", "capacity": 0,
				"fort_bonus": 0.3, "training_speed": 1.0, "upkeep": 0.05,
				"build_days": 20,
				"material_goods": PackedInt32Array([0]), "material_qty": PackedInt64Array([40000])},
			{"id": "stone_walls", "name": "石砌城墙", "role": 1, "tier": 2,
				"unlock_tech_id": "tech.masonry", "capacity": 0, "fort_bonus": 0.6,
				"training_speed": 1.0, "upkeep": 0.15, "build_days": 30,
				"material_goods": PackedInt32Array([0, 1, 2, 3]),
				"material_qty": PackedInt64Array([120000, 60000, 30000, 15000])},
			{"id": "martial_academy", "name": "武学馆", "role": 2, "tier": 1,
				"unlock_tech_id": "tech.military.standing_army", "capacity": 0,
				"fort_bonus": 0.0, "training_speed": 1.5, "upkeep": 0.2,
				"build_days": 40,
				"material_goods": PackedInt32Array([0]), "material_qty": PackedInt64Array([30000])},
		],
	}


func _snapshot() -> Dictionary:
	return {
		"ok": true, "cell": CELL, "owner_slot": 1, "controller_slot": 1,
		"post_count": 25, "present": 12, "pending_enlist": 3,
		"fort_tier": -1, "college_tier": -1, "paused": false, "disrepair": false,
		"barracks_tiers": PackedInt32Array([0, 0, 0, 1, 0, 0, 0, 0]),
		"construction_buildings": PackedInt32Array([-1, -1, -1]),
		"construction_done_days": PackedInt32Array([-1, -1, -1]),
		"armies": [{"handle": 0x100000002, "owner_slot": 1, "headcount": 300,
			"foreign": false}],
		"training": [{"id": 7, "country_slot": 1, "from_unit": 0, "to_unit": 1,
			"count": 12, "days_done": 8, "days_total": 30}],
		"garrison_lots": [],
	}


func _view_model(researched: PackedStringArray, snapshot: Dictionary,
		owned := true, treasury_empty := false,
		catalog_override: Dictionary = {}) -> Dictionary:
	var generator := FakeGenerator.new()
	var country := FakeCountryFacade.new()
	country.techs = researched
	country.owned = owned
	country.treasury_empty = treasury_empty
	var military := FakeMilitaryFacade.new()
	military.catalog_data = catalog_override if not catalog_override.is_empty() \
		else _catalog()
	military.snapshot_data = snapshot
	generator.country = country
	generator.military = military
	var vm = VIEW_MODEL_SCRIPT.new()
	vm.set_context(null, generator, null, null, 0.42, 22.0)
	return vm._military_category(CELL)


# ---------------------------------------------------------------- assertions

func _test_read_model() -> void:
	var category := _view_model(PackedStringArray(["tech.military.standing_army"]),
		_snapshot())
	for legacy in ["metrics", "gauges", "military_context", "kicker"]:
		if category.has(legacy):
			_failures.append("military page still emits legacy key %s" % legacy)
	if not category.has("military_cell"):
		_failures.append("military page did not emit military_cell")
		return
	var model: Dictionary = category["military_cell"]
	var buildings: Array = model.get("buildings", [])
	if buildings.size() != 3:
		_failures.append("expected 3 building rows, got %d" % buildings.size())
		return
	var roles := []
	for row in buildings:
		roles.append(String((row as Dictionary).get("role", "")))
	if roles != ["barracks", "fortification", "war_college"]:
		_failures.append("building row order changed: %s" % [roles])
	var barracks: Dictionary = buildings[0]
	if String(barracks.get("name", "")) != "戍卫营":
		_failures.append("barracks row did not resolve the built tier name")
	if int(barracks.get("count", 0)) != 1:
		_failures.append("barracks row lost the per-tier count")
	if String(barracks.get("effect", "")) != "兵额 +25":
		_failures.append("barracks effect text: %s" % String(barracks.get("effect", "")))
	# 到顶档的兵营仍给「再建」：原生按档位计数累加兵额，UI 不该把主键换成拆除。
	if String(barracks.get("primary_action", "")) != "rebuild" \
			or int(barracks.get("target", -1)) != 1:
		_failures.append("barracks primary_action/target: %s/%d" % [
			String(barracks.get("primary_action", "")),
			int(barracks.get("target", -1))])
	if String(barracks.get("action_label", "")) != "再建":
		_failures.append("barracks action label: %s" % String(
			barracks.get("action_label", "")))
	# 拆除是独立通道，但仍要指出拆哪一档。
	if not bool(barracks.get("can_demolish", false)):
		_failures.append("barracks row lost its demolish channel")
	if int(barracks.get("demolish_target", -1)) != 1:
		_failures.append("barracks demolish_target: %d" % int(
			barracks.get("demolish_target", -1)))
	if String(barracks.get("action", "")) != "rebuild":
		_failures.append("barracks display action: %s" % String(
			barracks.get("action", "")))
	var garrison: Dictionary = model.get("garrison", {})
	if int(garrison.get("present", 0)) != 12 or int(garrison.get("posts", 0)) != 25 \
			or int(garrison.get("pending", 0)) != 3:
		_failures.append("garrison readout lost present/posts/pending")
	# 数据带必须给出空额/兵营座数/训练速度，哪怕全是 0：这是玩家判断状态的依据。
	if int(garrison.get("open", -1)) != 10:
		_failures.append("garrison open slots: %d" % int(garrison.get("open", -1)))
	if int(garrison.get("barracks_count", -1)) != 1:
		_failures.append("barracks count: %d" % int(garrison.get("barracks_count", -1)))
	if absf(float(garrison.get("training_speed", 0.0)) - 1.0) > 0.001:
		_failures.append("training speed without a college should be 1.0, got %s"
			% str(garrison.get("training_speed", 0.0)))
	var troops: Array = model.get("troops", [])
	if troops.size() != 1:
		_failures.append("troop rows: %d" % troops.size())
	else:
		if String((troops[0] as Dictionary).get("name", "")) != "第 3 军":
			_failures.append("troop name: %s" % String(
				(troops[0] as Dictionary).get("name", "")))
		if int((troops[0] as Dictionary).get("handle", 0)) == 0:
			_failures.append("troop row lost its handle")
	var training: Array = model.get("training", [])
	if training.size() != 1:
		_failures.append("training rows: %d" % training.size())
	else:
		var order: Dictionary = training[0]
		if String(order.get("to", "")) != "长枪兵" or String(order.get("from", "")) != "民兵":
			_failures.append("training unit names not resolved from the catalog")
		if int(order.get("remaining_days", -1)) != 22:
			_failures.append("training remaining days: %d" % int(
				order.get("remaining_days", -1)))
		if absf(float(order.get("progress", 0.0)) - 8.0 / 30.0) > 0.001:
			_failures.append("training progress: %s" % str(order.get("progress", 0.0)))


func _test_tech_gate() -> void:
	var locked := _view_model(PackedStringArray(), _snapshot())
	var fort_locked: Dictionary = (locked["military_cell"]["buildings"] as Array)[1]
	if String(fort_locked.get("action", "")) != "locked":
		_failures.append("locked fortification row offers %s" % String(
			fort_locked.get("action", "")))
	if int(fort_locked.get("target", -1)) != -1:
		_failures.append("locked fortification row carries a build target")
	# 全锁着也要给出"下一档叫什么、能给什么效果"：行里不能只剩一个类目名。
	if String(fort_locked.get("name", "")) != "夯土城垣" \
			or String(fort_locked.get("effect", "")) != "守备 +30%":
		_failures.append("locked fortification row is bare: %s / %s" % [
			String(fort_locked.get("name", "")), String(fort_locked.get("effect", ""))])
	var unlocked := _view_model(PackedStringArray(["tech.masonry"]), _snapshot())
	var fort_build: Dictionary = (unlocked["military_cell"]["buildings"] as Array)[1]
	if String(fort_build.get("action", "")) != "build":
		_failures.append("unlocked fortification row offers %s" % String(
			fort_build.get("action", "")))
	if int(fort_build.get("target", -1)) != 3:
		_failures.append("fortification build target is not the highest unlocked row: %d" % int(
			fort_build.get("target", -1)))
	if String(fort_build.get("effect", "")) != "守备 +60%":
		_failures.append("fortification effect: %s" % String(fort_build.get("effect", "")))
	# 可建造的行必须带上建材与工期：这正是本次改动要补的那一类信息。
	var materials_text := String(fort_build.get("materials_text", ""))
	if materials_text.is_empty():
		_failures.append("buildable fortification row carries no material cost")
	if String(fort_build.get("materials_text", "")) == "无需建材":
		# 目录里没有建材才允许写「无需建材」；这里已给出石料需求，不该落到该分支。
		_failures.append("buildable fortification row claims zero materials")
	if String(fort_build.get("cost_days_text", "")).is_empty():
		_failures.append("buildable fortification row lost its build days")
	if String(fort_build.get("tooltip", "")).is_empty():
		_failures.append("buildable fortification row has no tooltip text")
	var college: Dictionary = (unlocked["military_cell"]["buildings"] as Array)[2]
	if String(college.get("action", "")) != "locked":
		_failures.append("war college row ignored the standing-army gate")
	# 锁定态没有可下单目标，就不该编一份不会兑现的报价。
	if not String(college.get("materials_text", "")).is_empty() \
			and String(college.get("primary_action", "")) == "none" \
			and int(college.get("target", -1)) < 0 \
			and not String(college.get("materials_text", "")).is_empty():
		_failures.append("locked row reports a buildable cost: %s" % String(
			college.get("materials_text", "")))
	# 别国领土：按钮全部收掉，但数据照常显示。
	var foreign := _view_model(PackedStringArray(["tech.masonry"]), _snapshot(), false)
	for raw in (foreign["military_cell"]["buildings"] as Array):
		var row: Dictionary = raw
		if String(row.get("action", "")) != "unavailable":
			_failures.append("%s row still offers an action on foreign land" % String(
				row.get("role", "")))


## 缺建材时必须说清因由，并收回主键：给一个按下去注定被拒的键比不给更糟。
func _test_cost_blocking() -> void:
	var blocked := _view_model(PackedStringArray(["tech.masonry"]), _snapshot(),
		true, true)
	var fort: Dictionary = (blocked["military_cell"]["buildings"] as Array)[1]
	if String(fort.get("cost_reason", "")) != "缺建材":
		_failures.append("blocked fortification cost_reason: %s" % String(
			forth_line(fort)))
	if String(fort.get("primary_action", "none")) != "none":
		_failures.append("blocked fortification still offers %s" % String(
			fort.get("primary_action", "")))
	# 缺料时成本本身仍要显示：玩家得知道差多少，才知道去攒什么。
	if String(fort.get("materials_text", "")).is_empty():
		_failures.append("blocked fortification dropped its material text")
	if not String(fort.get("tooltip", "")).contains("缺建材"):
		_failures.append("blocked fortification tooltip omits the reason")
	# 提示卡是玩家核对清单的唯一落点：行内可以写「等 N 项」，
	# 提示卡必须一种不漏，还要给出合计与每日维护。
	var tooltip := String(fort.get("tooltip", ""))
	for raw in (fort.get("materials_detail", []) as Array):
		var material: Dictionary = raw
		var name := String(material.get("name", ""))
		if name.is_empty():
			continue
		if not tooltip.contains(name):
			_failures.append("tooltip omits material '%s'" % name)
	if not tooltip.contains("维护"):
		_failures.append("tooltip omits the upkeep line")


## 升级必须整行描述**目标档**：名称、工期、建材指向同一座建筑。
## 旧实现在这里名称取现有档、报价取目标档，玩家看到「戍卫营」却报着别的档的料。
func _test_upgrade_describes_target_tier() -> void:
	# 夹具：tier 1 = 战士营地（10 日 / upkeep 0.02），tier 3 = 戍卫营（30 日 / 0.15）。
	# 先建 tier 1，最高已解锁档是 tier 3，升级时整行必须描述 tier 3。
	# `barracks_tiers` 的下标就是目录的 tier 值（原生 `barracks_count[tier]`），
	# 下标 0 恒为空：写成 [1,0,…] 会被读成「档位 0 有一座」，而目录没有档位 0。
	var low := _snapshot()
	low["barracks_tiers"] = PackedInt32Array([0, 1, 0, 0, 0, 0, 0, 0])
	low["post_count"] = 4
	var upgraded := _view_model(PackedStringArray(["tech.military.standing_army"]),
		low)
	var row: Dictionary = (upgraded["military_cell"]["buildings"] as Array)[0]
	if String(row.get("primary_action", "")) != "upgrade":
		_failures.append("tier-1 barracks should offer upgrade, got %s" % String(
			row.get("primary_action", "")))
		return
	if String(row.get("name", "")) != "戍卫营":
		_failures.append("upgrade row names the current tier: %s" % String(
			row.get("name", "")))
	if String(row.get("cost_days_text", "")) != "30 日":
		_failures.append("upgrade row quotes the wrong build days: %s" % String(
			row.get("cost_days_text", "")))
	var tooltip := String(row.get("tooltip", ""))
	if not tooltip.contains("维护"):
		_failures.append("upgrade tooltip omits upkeep: %s" % tooltip)


## 「再建一座」的决策靠的是建成后的维护，而不是当下这 N 座：提示卡必须写清
## 建完之后一共几座、每天一共多少。同档再建是 (N+1) 座相加。
func _test_upkeep_after_rebuild() -> void:
	var snapshot := _snapshot()
	snapshot["barracks_tiers"] = PackedInt32Array([0, 0, 0, 2, 0, 0, 0, 0])
	snapshot["post_count"] = 50
	var view := _view_model(PackedStringArray(["tech.military.standing_army"]),
		snapshot)
	var barracks: Dictionary = (view["military_cell"]["buildings"] as Array)[0]
	if String(barracks.get("primary_action", "")) != "rebuild":
		_failures.append("two barracks should still offer rebuild, got %s" % String(
			barracks.get("primary_action", "")))
		return
	var tooltip := String(barracks.get("tooltip", ""))
	if not tooltip.contains("现有 2 座"):
		_failures.append("rebuild tooltip lost the current stack count: %s" % tooltip)
	if not tooltip.contains("建成后 3 座"):
		_failures.append("rebuild tooltip omits the 3-stack upkeep: %s" % tooltip)
	# 0.15/日 x 3 = 0.45/日
	if not tooltip.contains("0.45"):
		_failures.append("rebuild upkeep total should be 0.45/day: %s" % tooltip)


## 升级时旧档被新档替换，维护按新档单份算，不能把两档相加。
func _test_upkeep_after_upgrade() -> void:
	var low := _snapshot()
	# 下标 = 目录 tier：tier 1 有 1 座（战士营地），可升级到 tier 3（戍卫营）。
	low["barracks_tiers"] = PackedInt32Array([0, 1, 0, 0, 0, 0, 0, 0])
	low["post_count"] = 4
	var view := _view_model(PackedStringArray(["tech.military.standing_army"]),
		low)
	var row: Dictionary = (view["military_cell"]["buildings"] as Array)[0]
	var tooltip := String(row.get("tooltip", ""))
	if not tooltip.contains("升级后"):
		_failures.append("upgrade tooltip omits the post-upgrade upkeep: %s" % tooltip)
	# 新档 0.15/日；若错写成两档相加会出现 0.17。
	if tooltip.contains("0.17"):
		_failures.append("upgrade summed both tiers' upkeep: %s" % tooltip)


## 维护成本必须逐座合计：两座兵营只报一座的钱，会让玩家低估 upkeep。
## 提示卡里同时写出单价与合计，玩家做「再建一座」决策时才有正确依据。
func _test_upkeep_totals() -> void:
	var snapshot := _snapshot()
	# 两座戍卫营（tier 3，upkeep 0.15/日）：合计必须是 0.30/日。
	snapshot["barracks_tiers"] = PackedInt32Array([0, 0, 0, 2, 0, 0, 0, 0])
	snapshot["post_count"] = 50
	var view := _view_model(PackedStringArray(["tech.military.standing_army"]),
		snapshot)
	var barracks: Dictionary = (view["military_cell"]["buildings"] as Array)[0]
	var tooltip := String(barracks.get("tooltip", ""))
	if not tooltip.contains("维护"):
		_failures.append("barracks tooltip omits upkeep: %s" % tooltip)
		return
	if not tooltip.contains("现有 2 座"):
		_failures.append("barracks upkeep does not total both stacks: %s" % tooltip)
	if not tooltip.contains("0.3"):
		_failures.append("barracks upkeep total should be 0.30/day: %s" % tooltip)


## 单座时不该出现「现有 N 座」的噪音：那句话只在多座时有决策价值。
func _test_upkeep_single_stack_is_quiet() -> void:
	var view := _view_model(PackedStringArray(["tech.military.standing_army"]),
		_snapshot())
	var barracks: Dictionary = (view["military_cell"]["buildings"] as Array)[0]
	var tooltip := String(barracks.get("tooltip", ""))
	if tooltip.contains("现有 1 座"):
		_failures.append("single-stack upkeep should not mention the stack count")


## 展开的建材明细必须与提示卡里的条目一一对应，不能一边截断一边声称全量。
## 用四项建材的档位来测：行内会被截断成「等 4 项」，提示卡必须一种不漏。
func _test_cost_detail_matches_tooltip() -> void:
	var unlocked := _view_model(PackedStringArray(["tech.masonry"]), _snapshot())
	var fort: Dictionary = (unlocked["military_cell"]["buildings"] as Array)[1]
	var detail: Array = fort.get("materials_detail", [])
	if detail.size() < 4:
		_failures.append("expected a four-material fixture, got %d" % detail.size())
	# 行内文本允许截断，但必须点明还有几项，否则玩家不知道提示卡里还有内容。
	if not String(fort.get("materials_text", "")).contains("等"):
		_failures.append("row text should truncate and say 等 N 项: %s" % String(
			fort.get("materials_text", "")))
	var tooltip := String(fort.get("tooltip", ""))
	for raw in detail:
		var material: Dictionary = raw
		var name := String(material.get("name", ""))
		if name.is_empty():
			continue
		if not tooltip.contains(name):
			_failures.append("tooltip dropped material '%s'" % name)
	if not tooltip.contains("建材合计"):
		_failures.append("multi-material tooltip has no 建材合计 line")
	if not tooltip.contains("维护"):
		_failures.append("multi-material tooltip omits upkeep")


## 目录里没有配建材的档位（早期存档 / 简化目录）必须写「无需建材」，而不是留空白——
## 空白会被读成「成本还没读到」，与「确实不要料」是两件完全不同的事。
func _test_cost_without_materials() -> void:
	var catalog := _catalog()
	var rows: Array = catalog["state_buildings"]
	var patched: Array = []
	for raw in rows:
		var row: Dictionary = (raw as Dictionary).duplicate(true)
		row["material_goods"] = PackedInt32Array()
		row["material_qty"] = PackedInt64Array()
		patched.append(row)
	catalog["state_buildings"] = patched
	var category := _view_model(PackedStringArray(["tech.masonry"]), _snapshot(),
		true, false, catalog)
	var fort: Dictionary = (category["military_cell"]["buildings"] as Array)[1]
	if String(fort.get("materials_text", "")) != "无需建材":
		_failures.append("material-free row should say 无需建材, got '%s'" % String(
			fort.get("materials_text", "")))
	if not String(fort.get("cost_reason", "")).is_empty():
		_failures.append("material-free row reported a reason: %s" % String(
			forth_line(fort)))
	if String(fort.get("primary_action", "none")) != "build":
		_failures.append("material-free row still blocks building: %s" % String(
			forth_line(fort)))
	if not String(fort.get("tooltip", "")).contains("无需建材"):
		_failures.append("material-free tooltip does not state 无需建材")


func forth_line(row: Dictionary) -> String:
	return "reason=%s materials=%s action=%s" % [
		String(row.get("cost_reason", "")), String(row.get("materials_text", "")),
		String(row.get("primary_action", ""))]


func _test_construction_and_flags() -> void:
	var snapshot := _snapshot()
	snapshot["construction_buildings"] = PackedInt32Array([3, -1, -1])
	snapshot["construction_done_days"] = PackedInt32Array([60, -1, -1])
	snapshot["disrepair"] = true
	var category := _view_model(PackedStringArray(["tech.masonry"]), snapshot)
	var fort: Dictionary = (category["military_cell"]["buildings"] as Array)[1]
	if String(fort.get("action", "")) != "building":
		_failures.append("in-progress fortification row offers %s" % String(
			fort.get("action", "")))
	if int(fort.get("pending_days", -1)) != 60:
		_failures.append("in-progress fortification days: %d" % int(
			fort.get("pending_days", -1)))
	if bool((category["military_cell"]["garrison"] as Dictionary).get(
			"disrepair", false)) != true:
		_failures.append("disrepair flag dropped from the garrison strip")
	# 军校一建成，数据带上的训练速度就要从 ×1 变成该档的倍数（武学馆 = 1.5）。
	snapshot["college_tier"] = 1
	var with_college := _view_model(PackedStringArray(["tech.military.standing_army"]),
		snapshot)
	var speed := float((with_college["military_cell"]["garrison"] as Dictionary).get(
		"training_speed", 0.0))
	if absf(speed - 1.5) > 0.001:
		_failures.append("college tier 1 training speed: %s" % str(speed))


func _test_ledger_component() -> void:
	var root := Control.new()
	root.size = Vector2(460.0, 720.0)
	root.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	get_root().add_child(root)
	var ledger = LEDGER_SCENE.instantiate()
	root.add_child(ledger)
	# 显式给出 424px 页宽：这既是地块档案列的真实宽度，也是溢出断言要守的边界。
	ledger.size = Vector2(424.0, 720.0)
	await process_frame
	var category := _view_model(PackedStringArray(["tech.military.standing_army"]),
		_snapshot())
	var model: Dictionary = category["military_cell"]
	var requests: Array = []
	ledger.action_requested.connect(func(request: Dictionary) -> void:
		requests.append(request))
	ledger.set_model(model)
	await process_frame
	var rows: Array = ledger.building_rows()
	if rows.size() != 3:
		_failures.append("ledger built %d building rows" % rows.size())
		return
	var min_width: float = ledger.get_combined_minimum_size().x
	if min_width > 424.0:
		_failures.append("military ledger needs %s px, wider than the 424px dossier column"
			% str(min_width))
	# 成本必须能在 424px 里活着：主键常驻 + 次级键占位，即使在最窄页宽也不能把
	# 文字挤出容器，否则玩家看不到「这一座要吃掉多少建材」。
	for raw in rows:
		var row: Control = raw
		var primary: Button = row.action_button()
		var demolish: Button = row.demolish_button()
		if primary.visible and primary.position.x + primary.size.x > row.size.x + 1.0:
			_failures.append("%s primary chip overflows the 424px row" % row.name)
		if demolish.position.x + demolish.size.x > row.size.x + 1.0:
			_failures.append("%s demolish chip overflows the 424px row" % row.name)
		if demolish.position.x + demolish.size.x > primary.position.x + 0.5 \
				and demolish.visible:
			_failures.append("%s demolish chip overlaps the primary chip" % row.name)
	# 提示卡必须是能换行的纸片卡，而不是原生 tooltip：原生提示不折行，
	# 建材多项时会被压成一条长句甚至被屏幕边缘裁掉。
	# 只构建一张卡来验证换行行为，按钮侧只查是否绑定了纸片构建器，
	# 免得为了一次断言反复造节点。
	var probe_row: Control = rows[1]
	var card: Object = probe_row._make_custom_tooltip(
		String(probe_row.tooltip_text))
	if card == null:
		_failures.append("building row has no paper tooltip card")
	else:
		var card_root: Control = card
		var wrap_label: Label = null
		for child in card_root.get_children():
			if child is Label:
				wrap_label = child
				break
		if wrap_label == null:
			_failures.append("tooltip card has no text label")
		else:
			if wrap_label.autowrap_mode == TextServer.AUTOWRAP_OFF:
				_failures.append("tooltip label does not wrap")
			if wrap_label.text.strip_edges().is_empty():
				_failures.append("tooltip card is empty")
		card_root.free()
	for raw in rows:
		var row: Control = raw
		# 悬停按钮时 Godot 只问按钮，裸 Button 会退回不换行的默认 TooltipPanel。
		for chip_raw in [row.action_button(), row.demolish_button()]:
			var chip: Button = chip_raw
			if not chip.has_method("_make_custom_tooltip"):
				_failures.append("%s chip cannot build a paper tooltip" % row.name)
				continue
			# 真调一次：绑定失效时它会返回 null，然后静默回退到原生提示。
			var chip_card: Object = chip._make_custom_tooltip("建材：木材 30")
			if chip_card == null:
				_failures.append("%s chip fell back to the native tooltip" % row.name)
			else:
				(chip_card as Control).free()
	var barracks_row = rows[0]
	if not barracks_row.action_button().visible:
		_failures.append("barracks action button hidden while rebuild is available")
	if barracks_row.action_button().text != "再建":
		_failures.append("barracks action label: %s" % barracks_row.action_button().text)
	# 拆除键默认不显形：破坏性操作不能和主键抢同一落点。
	if barracks_row.demolish_button().visible:
		_failures.append("demolish chip visible without hover")
	# 主键按下只发正向命令：到顶档是「再建」，仍是 state.build。
	barracks_row.action_button().pressed.emit()
	if requests.size() != 1:
		_failures.append("ledger did not emit a build request")
	else:
		var request: Dictionary = requests[0]
		if String(request.get("op", "")) != "state.build" \
				or int(request.get("building", -1)) != 1 \
				or int(request.get("cell", -1)) != CELL:
			_failures.append("rebuild request shape: %s" % [request])
	ledger.release_busy()
	# 拆除键：悬停后显形，第一次按下只进入待确认，第二次才发命令。
	barracks_row.mouse_entered.emit()
	if not barracks_row.demolish_button().visible:
		_failures.append("demolish chip stayed hidden while hovering the row")
	requests.clear()
	barracks_row.demolish_button().pressed.emit()
	if not barracks_row.confirm_pending():
		_failures.append("demolish chip did not enter the confirm state")
	if not requests.is_empty():
		_failures.append("demolish emitted a command on the first press")
	barracks_row.demolish_button().pressed.emit()
	if barracks_row.confirm_pending():
		_failures.append("demolish chip stayed in confirm state after the second press")
	if requests.size() != 1:
		_failures.append("demolish did not emit after confirmation")
	else:
		var demolish_request: Dictionary = requests[0]
		if String(demolish_request.get("op", "")) != "state.demolish" \
				or int(demolish_request.get("building", -1)) != 1:
			_failures.append("demolish request shape: %s" % [demolish_request])
	# 待确认态必须能被撤回：一是指针离开这一行，二是新模型落地（对象可能已经变了）。
	ledger.release_busy()
	requests.clear()
	barracks_row.demolish_button().pressed.emit()
	if not barracks_row.confirm_pending():
		_failures.append("demolish chip did not re-enter the confirm state")
	barracks_row.mouse_exited.emit()
	if barracks_row.confirm_pending():
		_failures.append("pointer leaving the row did not cancel the demolish confirm")
	if requests.size() != 0:
		_failures.append("cancelling the demolish confirm still emitted a command")
	barracks_row.mouse_entered.emit()
	barracks_row.demolish_button().pressed.emit()
	if not barracks_row.confirm_pending():
		_failures.append("demolish chip did not enter the confirm state before refresh")
	ledger.set_model(model.duplicate(true))
	await process_frame
	if barracks_row.confirm_pending():
		_failures.append("a fresh model kept the stale demolish confirm")
	ledger.release_busy()
	# 第三条撤回路径：待确认态超时自动失效。直接把截止时刻推到过去再走一帧 _process，
	# 不必真等 3 秒（等待会让这个测试在 CI 上变成慢测试）。
	barracks_row.mouse_entered.emit()
	barracks_row.demolish_button().pressed.emit()
	if not barracks_row.confirm_pending():
		_failures.append("demolish chip did not enter the confirm state before timeout")
	barracks_row._confirm_until_msec = Time.get_ticks_msec() - 1
	barracks_row._process(0.0)
	if barracks_row.confirm_pending():
		_failures.append("the demolish confirm did not expire on its own deadline")
	if not requests.is_empty():
		_failures.append("an expired demolish confirm still emitted a command")
	ledger.release_busy()
	var fort_row = rows[1]
	if fort_row.action_button().visible:
		_failures.append("locked fortification row still shows a button")
	ledger.release_busy()
	# 同一身份重复 set_model：节点数必须不变（每日补丁走这条路径）。
	var nodes_before: int = _count_nodes(ledger)
	ledger.set_model(model.duplicate(true))
	await process_frame
	if _count_nodes(ledger) != nodes_before:
		_failures.append("ledger node count changed on a refresh")
	if not barracks_row.action_button().visible:
		_failures.append("ledger stayed busy after a fresh model")
	# 命令被拒时通过 release_busy() 解锁，不必等下一次日推进。
	barracks_row.action_button().pressed.emit()
	if not barracks_row.action_button().disabled:
		_failures.append("action button stayed enabled after a press")
	# 命令回执落在刚按下那一行上：地块档案这一页是它唯一的可见回音，
	# 营造反馈条只在营造窗口打开时可见，不能被当成这一页的反馈。
	ledger.show_feedback("尚未解锁这项科技。", false)
	if ledger.feedback_text() != "尚未解锁这项科技。":
		_failures.append("ledger feedback did not land on the pressed row: '%s'" % \
			ledger.feedback_text())
	ledger.release_busy()
	if barracks_row.action_button().disabled:
		_failures.append("release_busy() did not re-enable the action button")
	root.queue_free()
	await process_frame


func _test_panel_integration() -> void:
	var root := Control.new()
	root.size = Vector2(1280.0, 720.0)
	root.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	get_root().add_child(root)
	var panel := PANEL_SCENE.instantiate()
	root.add_child(panel)
	panel.visible = true
	await process_frame
	var category := _view_model(PackedStringArray(["tech.military.standing_army"]),
		_snapshot())
	var model := {
		"cell_index": CELL,
		"header": {"kicker": "区域 1, 1", "title": "低地 · 平原", "subtitle": "测试国"},
		"kpis": [],
		"tabs": [
			{"id": "geography", "label": "地理", "icon": "geo"},
			{"id": "military", "label": "军事", "icon": "country.military"},
		],
		"categories": {"geography": {}, "military": category},
	}
	panel.set_model_for_selection(model)
	panel.select_tab("military")
	await process_frame
	await process_frame
	if panel._military_ledger == null:
		_failures.append("inspector panel did not mount the military ledger")
		root.queue_free()
		await process_frame
		return
	var nodes_before: int = panel.visible_node_count()
	panel.apply_live_patch({
		"tab_id": "military",
		"category": _view_model(PackedStringArray(["tech.military.standing_army"]),
			_snapshot()),
	})
	await process_frame
	if panel.visible_node_count() != nodes_before:
		_failures.append("military live patch changed the inspector node count")
	root.queue_free()
	await process_frame


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count
