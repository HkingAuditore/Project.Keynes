extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const WorkspaceScene = preload("res://scenes/ui/ideology_workspace.tscn")

var _checks := 0
var _failures := 0


func _init() -> void:
	var economy_facade := EconomyFacadeScript.new()
	_expect("economy facade exposes its compiled catalog",
		economy_facade.has_method("native_catalog"))
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for ideology classes",
		bool(economy_ir.get("ok", false)))
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	_expect("default ideology catalog loads", ideology_catalog != null)
	if ideology_catalog != null and bool(economy_ir.get("ok", false)):
		var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
			economy_ir, economy_ir)
		_expect("default ideology catalog compiles",
			bool(ideology_ir.get("ok", false)))
		if bool(ideology_ir.get("ok", false)):
			_expect("minimum playable ideology set exists",
				(ideology_ir.ideology_ids as PackedStringArray).size() >= 4)
			_expect("directional stances compile to sparse rows",
				(ideology_ir.stance_class_indices as PackedInt32Array).size() >= 8)
			_expect("exclusive ideology pair is compiled",
				_count_nonnegative(ideology_ir.exclusion_group_ids) >= 2)
			_expect("two synergies and reverse CSR are compiled",
				(ideology_ir.synergy_ids as PackedStringArray).size() >= 2
				and (ideology_ir.ideology_synergy_ids as PackedInt32Array).size() >= 4)
			_expect("two-level persistent effects are authored",
				(ideology_ir.persistent_actions as PackedInt32Array).size() >= 8)
			_expect("production catalog endows starting ideology points",
				int(ideology_ir.get("starting_points_q16", 0)) >= 65536)
			_expect("each idea uses a dedicated country modifier",
				_unique_count(ideology_ir.persistent_definition_keys) >= 4)
			_expect("production ideas are not a shared mobilization stub",
				not (ideology_ir.persistent_definition_keys as PackedStringArray).has(
					"country.economic_mobilization"))
			var ideology_view: Dictionary = ideology_catalog.catalog_view(
				economy_ir, economy_ir)
			_expect("catalog view exposes player-facing effect lines",
				bool(ideology_view.get("ok", false)))
			if bool(ideology_view.get("ok", false)):
				var by_name := {}
				for row_value in ideology_view.get("ideologies", []):
					var row: Dictionary = row_value
					var levels: Array = row.get("level_effect_lines", [])
					var low := PackedStringArray(levels[0]) if not levels.is_empty() \
						else PackedStringArray()
					by_name[String(row.get("display_name", ""))] = "、".join(low)
				_expect("collective stewardship names agriculture and drought",
					String(by_name.get("共同体治理", "")).contains("农业")
					and String(by_name.get("共同体治理", "")).contains("旱灾"))
				_expect("free exchange names trade capacity",
					String(by_name.get("自由交换", "")).contains("贸易"))
				_expect("scholar office names science research",
					String(by_name.get("学识官署", "")).contains("科学"))
				_expect("civic muster names construction time",
					String(by_name.get("公民动员", "")).contains("建设"))
				_expect("the four roads do not share one effect line",
					String(by_name.get("共同体治理", "")) \
						!= String(by_name.get("自由交换", ""))
					and String(by_name.get("学识官署", "")) \
						!= String(by_name.get("公民动员", "")))
	var modifier_catalog: Resource = ModifierCatalogScript.load_default()
	_expect("default modifier catalog loads for ideology definitions",
		modifier_catalog != null)
	if modifier_catalog != null:
		var modifier_ir: Dictionary = modifier_catalog.compile_native_catalog()
		_expect("modifier catalog compiles with ideology definitions",
			bool(modifier_ir.get("ok", false))
			and (modifier_ir.definition_keys as PackedStringArray).has(
				"ideology.collective_stewardship"))
		var collective_lines: PackedStringArray = modifier_catalog.present_definition(
			&"ideology.collective_stewardship", 65536)
		_expect("modifier presenter formats stewardship at full magnitude",
			collective_lines.size() >= 2
			and String(collective_lines[0]).contains("+6%"))
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("shared Effect catalog includes ideology templates",
		effect_catalog != null)
	if effect_catalog != null:
		_expect("shared Effect IR compiles",
			bool(effect_catalog.compile_native_catalog().get("ok", false)))
	var workspace := WorkspaceScene.instantiate()
	root.add_child(workspace)
	workspace.set_model({"country_handle": 0, "current_day": 0,
		"ideology": {"available": false, "reason": "smoke"}})
	_expect("ideology workspace scene instantiates", workspace != null
		and workspace.has_method("set_player_controller"))
	_expect("offer cards and dialog are authored in the workspace scene",
		workspace.get_node_or_null("%Choice0") != null
		and workspace.get_node_or_null("%Choice1") != null
		and workspace.get_node_or_null("%Choice2") != null
		and workspace.get_node_or_null("%Collection") != null
		and workspace.get_node_or_null("%PromotionDialog") != null)
	_expect("unavailable model keeps the empty cabinet card",
		bool(workspace.call("empty_state_visible"))
		and String(workspace.call("hint_text")) == "smoke")
	var presented: Dictionary = CountryViewModel.present_ideology({
		"ok": true,
		"materialized": false,
		"ideology_points_q16": 0,
	}, {
		"ok": true,
		"ideology_capacity": 3,
		"national_spirit_capacity": 2,
		"offer_cost_q16": 65536,
		"starting_points_q16": 196608,
	})
	_expect("presentation falls back to catalog slot capacity",
		int(presented.get("slots_capacity", 0)) == 3
		and int(presented.get("spirits_capacity", 0)) == 2)
	_expect("presentation previews starting ideology points",
		String(presented.get("points_text", "")) == "3.00"
		and bool(presented.get("can_open_offer", false)))
	workspace.set_model({
		"country_handle": 1,
		"current_day": 0,
		"ideology": {
			"available": true,
			"snapshot": {
				"ok": true,
				"materialized": false,
				"ideology_points_q16": 196608,
				"offer_cost_q16": 65536,
				"ideology_slots_used": 0,
				"ideology_slots_capacity": 3,
				"national_spirit_slots_used": 0,
				"national_spirit_slots_capacity": 2,
				"known_ids": PackedInt32Array(),
				"offer_active": false,
			},
			"catalog": {"ok": true, "ideologies": []},
			"presentation": presented,
		},
	})
	_expect("playable empty collection shows the draw action",
		not bool(workspace.call("offer_button_disabled"))
		and bool(workspace.call("empty_state_visible"))
		and int(workspace.call("slots_capacity")) == 3
		and not String(workspace.call("hint_text")).contains("暂不可用"))
	var offer_card := CountryViewModel.present_ideology_card({
		"display_name": "共同体治理",
		"detail_key": "以共同仓储组织生产。",
		"icon_key": "country.economy",
		"level_effect_lines": [
			PackedStringArray(["农业部门产出 +6%", "旱灾损失 -8%"]),
			PackedStringArray(["农业部门产出 +12%", "旱灾损失 -16%"]),
		],
		"exclusion_rivals": PackedStringArray(["自由交换"]),
		"synergy_names": PackedStringArray(["计划仓廪"]),
	}, 0)
	_expect("choice presentation lists mechanical effects",
		String(offer_card.get("summary", "")).contains("农业部门产出 +6%")
		and (offer_card.get("effects", []) as Array).size() >= 2)
	workspace.set_model({
		"country_handle": 1,
		"current_day": 0,
		"ideology": {
			"available": true,
			"snapshot": {
				"ok": true,
				"materialized": true,
				"ideology_points_q16": 0,
				"offer_cost_q16": 65536,
				"ideology_slots_used": 0,
				"ideology_slots_capacity": 3,
				"national_spirit_slots_used": 0,
				"national_spirit_slots_capacity": 2,
				"known_ids": PackedInt32Array(),
				"offer_active": true,
				"offer_ids": PackedInt32Array([0, 1, 2]),
				"offer_generation": 1,
			},
			"catalog": {
				"ok": true,
				"ideologies": [
					{
						"dense_id": 0,
						"display_name": "共同体治理",
						"detail_key": "以共同仓储组织生产。",
						"icon_key": "country.economy",
						"level_effect_lines": [
							PackedStringArray(["农业部门产出 +6%", "旱灾损失 -8%"]),
						],
					},
					{
						"dense_id": 1,
						"display_name": "自由交换",
						"detail_key": "以契约鼓励流通。",
						"icon_key": "country.trade",
						"level_effect_lines": [
							PackedStringArray(["国内贸易容量 +8%", "贸易速度 +6%"]),
						],
					},
					{
						"dense_id": 2,
						"display_name": "学识官署",
						"detail_key": "让记录进入公共决策。",
						"icon_key": "country.technology",
						"level_effect_lines": [
							PackedStringArray(["知识部门产出 +6%", "科学领域研究效率 +8%"]),
						],
					},
				],
			},
		},
	})
	var summaries: PackedStringArray = workspace.call("offer_choice_summaries")
	_expect("offer cards show named mechanical effects",
		summaries.size() == 3
		and String(summaries[0]).contains("农业部门产出")
		and String(summaries[1]).contains("国内贸易容量")
		and String(summaries[2]).contains("科学领域研究效率"))
	workspace.queue_free()
	print("ideology content: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _count_nonnegative(values: PackedInt32Array) -> int:
	var count := 0
	for value in values:
		if value >= 0:
			count += 1
	return count


func _unique_count(values: PackedStringArray) -> int:
	var seen := {}
	for value in values:
		seen[String(value)] = true
	return seen.size()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
