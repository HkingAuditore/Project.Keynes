extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const WorkspaceScene = preload("res://scenes/ui/ideology_workspace.tscn")

const EXPECTED_PUBLISHED_CARDS := 113
const EXPECTED_HOLDOUT_CARDS := [
	"idea.little_ice_age",
	"idea.air_conditioning",
	"idea.canal_corvee",
	"idea.grand_canal",
	"idea.irrigation_grid",
	"idea.shell_midden",
	"idea.cooperative",
	"idea.industrial_lab",
	"idea.tax_farming",
	"idea.land_value",
	"idea.light_levy",
	"idea.progressive_tax",
	"idea.ancestral_hall",
	"idea.clan_fields",
	"idea.philanthropy",
	"idea.merchant_houses",
	"idea.family_enterprise",
	"idea.petition_box",
	"idea.tax_holiday",
	"idea.mandate_of_heaven",
	"idea.sovereign_fund",
]
const EXPECTED_FACE_FIX_CARDS := [
	"idea.land_tax_reform",
	"idea.excise",
	"idea.gentry_patronage",
	"idea.labour_legislation",
]

var _checks := 0
var _failures := 0


func _init() -> void:
	var economy_facade := EconomyFacadeScript.new()
	_expect("economy facade exposes its compiled catalog",
		economy_facade.has_method("native_catalog"))
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for ideology classes",
		bool(economy_ir.get("ok", false)))
	# Built once, early: both the definition-closure check below and the shared
	# IR check at the end need it, and a second `build()` would double-load every
	# domain catalog for no benefit.
	_test_card_definitions_resolve()
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	_expect("default ideology catalog loads", ideology_catalog != null)
	if ideology_catalog != null and bool(economy_ir.get("ok", false)):
		var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
			economy_ir, economy_ir)
		_expect("default ideology catalog compiles",
			bool(ideology_ir.get("ok", false)))
		if bool(ideology_ir.get("ok", false)):
			var compiled_ids: PackedStringArray = ideology_ir.ideology_ids
			_expect("temporary content gate publishes exactly 113 cards",
				compiled_ids.size() == EXPECTED_PUBLISHED_CARDS)
			var leaked_holdouts := PackedStringArray()
			for held_out in EXPECTED_HOLDOUT_CARDS:
				if compiled_ids.has(held_out):
					leaked_holdouts.append(String(held_out))
			_expect("all 21 mechanically incomplete cards stay out of the pool",
				leaked_holdouts.is_empty())
			var missing_face_fixes := PackedStringArray()
			for fixed_card in EXPECTED_FACE_FIX_CARDS:
				if not compiled_ids.has(fixed_card):
					missing_face_fixes.append(String(fixed_card))
			_expect("all 4 face-only cards remain in the pool",
				missing_face_fixes.is_empty())
			_expect("directional stances compile to sparse rows",
				(ideology_ir.stance_class_indices as PackedInt32Array).size() >= 8)
			_expect("exclusive ideology pair is compiled",
				_count_nonnegative(ideology_ir.exclusion_group_ids) >= 2)
			_expect("named synergies plus twelve school resonances compile",
				(ideology_ir.synergy_ids as PackedStringArray).size() >= 24
				and (ideology_ir.ideology_synergy_ids as PackedInt32Array).size() >= 14)
			# Geography gates are the whole point of the conditional rewrite: a card
			# gated on a discovered resource / biome / landform can only enter the
			# pool for a player whose territory actually provides it.
			_expect("a third of the pool is gated on discovered geography",
				(ideology_ir.signal_requirements as PackedInt32Array).size() >= 30)
			var gate_offsets: PackedInt32Array = ideology_ir.gate_requirement_offsets
			_expect("geography gates compile as per-card requirement spans",
				gate_offsets.size() >= (ideology_ir.ideology_ids as PackedStringArray).size())
			var min_counts: PackedInt32Array = ideology_ir.get("synergy_min_counts", PackedInt32Array())
			var two_tier := 0
			var four_tier := 0
			for value in min_counts:
				two_tier += 1 if int(value) == 2 else 0
				four_tier += 1 if int(value) == 4 else 0
			# The temporary pool keeps every emitted tier reachable. The exact
			# counts are recomputed from the published roster below, so pruning
			# one card cannot leave a "4-card" bond that can never fire.
			_expect("only reachable resonance and route tiers compile",
				two_tier == 14 and four_tier == 11)
			var level_offsets: PackedInt32Array = ideology_ir.level_offsets
			var three_levels := level_offsets.size() == (ideology_ir.ideology_ids as PackedStringArray).size() + 1
			for index in range(1, level_offsets.size()):
				three_levels = three_levels and int(level_offsets[index]) - int(level_offsets[index - 1]) == 3
			_expect("every card authors three understanding levels", three_levels)
			_expect("levels gate at 0 / 4 / 12 understanding",
				int(ideology_ir.level_thresholds_q16[0]) == 0
				and int(ideology_ir.level_thresholds_q16[1]) == 262144
				and int(ideology_ir.level_thresholds_q16[2]) == 786432)
			_expect("ideology points start at zero and only accrue from growth",
				int(ideology_ir.get("starting_points_q16", -1)) == 0
				and int(ideology_ir.get("point_gain_cap_q16", 0)) > 0)
			_expect("every draw costs 6.0, +20% per draw, and reroll is half price",
				int(ideology_ir.get("offer_cost_q16", 0)) == 393216
				and int(ideology_ir.get("offer_cost_growth_percent", 0)) == 120
				and int(ideology_ir.get("offer_cost_max_q16", 0)) == 2147483647
				and int(ideology_ir.get("reroll_cost_percent", 0)) == 50)
			_expect("slot capacity grows through five technology milestones",
				int(ideology_ir.get("ideology_capacity", 0)) == 2
				and int(ideology_ir.get("national_spirit_capacity", 0)) == 1
				and int(ideology_ir.get("ideology_capacity_max", 0)) == 6
				and int(ideology_ir.get("national_spirit_capacity_max", 0)) == 3
				and (ideology_ir.get("capacity_unlock_technology_ids", PackedInt32Array()) as PackedInt32Array).size() == 5)
			_expect("each idea uses a dedicated country modifier",
				_unique_count(ideology_ir.persistent_definition_keys) >= 30)
			_expect("production ideas are not a shared mobilization stub",
				not (ideology_ir.persistent_definition_keys as PackedStringArray).has(
					"country.economic_mobilization"))
			var ideology_view: Dictionary = ideology_catalog.catalog_view(
				economy_ir, economy_ir)
			_expect("catalog view exposes player-facing effect lines",
				bool(ideology_view.get("ok", false)))
			if bool(ideology_view.get("ok", false)):
				var school_counts := {}
				var rarities := {}
				var eras := {}
				var total_cards := 0
				var effects_ok := true
				for row_value in ideology_view.get("ideologies", []):
					var card_row: Dictionary = row_value
					var school := String(card_row.get("school_id", ""))
					school_counts[school] = int(school_counts.get(school, 0)) + 1
					rarities[int(card_row.get("rarity", 0))] = true
					eras[int(card_row.get("era_index", 0))] = true
					total_cards += 1
					for lines in card_row.get("level_effect_lines", []) as Array:
						effects_ok = effects_ok and not (lines as PackedStringArray).is_empty()
				# The pool depth is what keeps a late-game player from exhausting the
				# draw, so the floor matters more than the exact count.
				_expect("six schools carry at least five cards each and the pool holds 60+",
					school_counts.size() == 6 and not school_counts.has("")
					and school_counts.values().all(func(count) -> bool: return int(count) >= 5)
					and total_cards >= 60)
				_expect("cards are spread across every era instead of clustering at the start",
					eras.size() >= 9 and eras.has(0) and eras.has(10))
				_expect("common, rare and legendary rarities are all present",
					rarities.has(1) and rarities.has(2) and rarities.has(3))
				_expect("every level of every card presents effect text", effects_ok)
				var face_lines := {
					"摊丁入亩": PackedStringArray(),
					"消费税制": PackedStringArray(),
					"乡绅": PackedStringArray(),
					"劳动立法": PackedStringArray(),
				}
				for row_value in ideology_view.get("ideologies", []):
					var row: Dictionary = row_value
					var display := String(row.get("display_name", ""))
					if face_lines.has(display):
						var levels: Array = row.get("level_effect_lines", [])
						for level_index in levels.size():
							face_lines[display].append(
								"、".join(levels[level_index] as PackedStringArray))
				var land_tax_lines := ",".join(face_lines["摊丁入亩"])
				var excise_lines := ",".join(face_lines["消费税制"])
				var gentry_lines := ",".join(face_lines["乡绅"])
				var labour_lines := ",".join(face_lines["劳动立法"])
				_expect("land tax reform renders tolerance and landlord satisfaction",
					land_tax_lines.contains("对税负的承受能力")
					and land_tax_lines.contains("地主满意度降低 8 点"))
				_expect("excise merges profession tolerance terms",
					excise_lines.contains("全国各职业对税负的承受能力提高 8%")
					and not excise_lines.contains("税负容忍度"))
				_expect("gentry patronage renders tenant satisfaction",
					gentry_lines.contains("佃农、分成佃农、农奴满意度降低 2 点"))
				_expect("labour legislation renders worker satisfaction",
					labour_lines.contains("产业工人、矿工满意度提高 4 点"))
				_expect("slot unlock milestones carry technology display names",
					(ideology_view.get("capacity_unlock_technology_names", PackedStringArray()) as PackedStringArray).has("王国体系"))
				var by_name := {}
				for row_value in ideology_view.get("ideologies", []):
					var row: Dictionary = row_value
					var levels: Array = row.get("level_effect_lines", [])
					var low := PackedStringArray(levels[0]) if not levels.is_empty() \
						else PackedStringArray()
					by_name[String(row.get("display_name", ""))] = "、".join(low)
				# 共同体治理 is now an X1 spillover card: its face line says which
				# cells it radiates from, not which national stats it moves.
				_expect("collective stewardship names its agricultural source ring",
					String(by_name.get("共同体治理", "")).contains("以农业为主")
					and String(by_name.get("共同体治理", "")).contains("周围"))
				# 自由交换 moved to a cell-level program this round: its card face
				# line is the program summary, not a Modifier presenter line. This
				# is the assertion that notices if the summary chain breaks and the
				# card would render its cost and nothing else.
				_expect("free exchange names all-output on diversified cells",
					String(by_name.get("自由交换", "")).contains("全部产出"))
				_expect("scholar office names its knowledge-cell program",
					String(by_name.get("学识官署", "")).contains("知识产出"))
				# The card table is now conditional: 冶铁 must read as an input-side
				# effect on a specific good rather than a flat national multiplier.
				_expect("iron smelting names the ring around iron cells",
					String(by_name.get("冶铁", "")).contains("工业产出")
					and String(by_name.get("冶铁", "")).contains("铁矿石"))
				_expect("terrace farming names the terrain it targets",
					String(by_name.get("梯田", "")).contains("丘陵"))
				_expect("the four roads do not share one effect line",
					String(by_name.get("共同体治理", "")) \
						!= String(by_name.get("自由交换", ""))
					and String(by_name.get("学识官署", "")) \
						!= String(by_name.get("公民动员", "")))
	var modifier_catalog: Resource = ModifierCatalogScript.load_default()
	_expect("default modifier catalog loads for ideology definitions",
		modifier_catalog != null)
	if modifier_catalog != null:
		_expect("tax tolerance reads as a plain-language capacity",
			ModifierCatalogScript.present_stat_delta(
				"economy.profession.tenant_farmer.tax_tolerance_factor", 2, 1.3,
				ModifierCatalogScript.Q16_ONE, true)
				== "佃农对税负的承受能力提高 30%")
		_expect("satisfaction basis points read as satisfaction points",
			ModifierCatalogScript.present_stat_delta(
				"economy.profession.landlord.satisfaction_bp", 0, -800.0,
				ModifierCatalogScript.Q16_ONE, true)
				== "地主满意度降低 8 点")
		_expect("tax rates read as percentage points in plain language",
			ModifierCatalogScript.present_stat_delta(
				"country.tax.income.miner.rate_bp", 0, 150,
				ModifierCatalogScript.Q16_ONE, true)
				== "矿工所得税率提高 1.5 个百分点")
		_expect("the public stat presenter keeps its legacy formatting",
			ModifierCatalogScript.present_stat_delta(
				"economy.profession.landlord.satisfaction_bp", 0, -800.0)
				== "地主 -8.00 点")
		var excise_definition_lines: PackedStringArray = \
			modifier_catalog.present_definition_for_ideology(&"ideology.excise.l1")
		_expect("the ideology presenter collapses repeated profession terms",
			excise_definition_lines.size() <= 6
			and excise_definition_lines.has("全国各职业对税负的承受能力提高 8%"))
		var modifier_ir: Dictionary = modifier_catalog.compile_native_catalog()
		_expect("modifier catalog compiles with ideology definitions",
			bool(modifier_ir.get("ok", false))
			and (modifier_ir.definition_keys as PackedStringArray).has(
				"ideology.collective_stewardship"))
		if ideology_catalog != null and bool(economy_ir.get("ok", false)) \
				and bool(modifier_ir.get("ok", false)):
			var keys_ir: Dictionary = ideology_catalog.compile_native_catalog(economy_ir, economy_ir)
			var known_keys: PackedStringArray = modifier_ir.definition_keys
			# A row that routes to a managed program names the *program*, not a
			# Modifier definition. Those keys are owned by the effect catalog and
			# are checked by `ideology_gate_chain_test` end to end; what must hold
			# here is that every NON-program row still resolves to a Modifier.
			var declared_programs: Dictionary = {}
			var program_catalog: Resource = IdeologyEffectCatalogScript.load_default()
			if program_catalog != null and program_catalog.has_method("program_key_set"):
				declared_programs = program_catalog.program_key_set()
			var missing := PackedStringArray()
			for key in keys_ir.get("persistent_definition_keys", PackedStringArray()) as PackedStringArray:
				if declared_programs.has("ideology.effect." + String(key)):
					continue
				if not known_keys.has(String(key)):
					missing.append(String(key))
			_expect("every ideology/synergy/resonance definition exists in the modifier catalog",
				missing.is_empty())
			_expect("point gain stat is a registered country stat",
				(modifier_ir.get("stat_keys", PackedStringArray()) as PackedStringArray).has(
					"country.ideology.point_gain_factor")
				or String(keys_ir.get("point_gain_stat_key", "")) == "country.ideology.point_gain_factor")
		var collective_lines: PackedStringArray = modifier_catalog.present_definition(
			&"ideology.collective_stewardship", 65536)
		# The benefit moved into the program; the definition that is left is the
		# cost, so the presenter must still render one line for it.
		_expect("modifier presenter formats stewardship cost line",
			collective_lines.size() >= 1
			and String(collective_lines[0]).contains("-3%"))
	var effect_catalog_built: Resource = effect_catalog
	_expect("shared Effect catalog includes ideology templates",
		effect_catalog_built != null)
	if effect_catalog_built != null:
		_expect("shared Effect IR compiles",
			bool(effect_catalog_built.compile_native_catalog().get("ok", false)))
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
		"offer_cost_q16": 131072,
		"starting_points_q16": 0,
	})
	_expect("presentation falls back to catalog slot capacity",
		int(presented.get("slots_capacity", 0)) == 3
		and int(presented.get("spirits_capacity", 0)) == 2)
	_expect("presentation no longer invents starting points",
		String(presented.get("points_text", "")) == "0.00"
		and not bool(presented.get("can_open_offer", false))
		and String(presented.get("offer_hint", "")).contains("2.00"))
	var escalated: Dictionary = CountryViewModel.present_ideology({
		"ok": true, "materialized": true, "ideology_points_q16": 196608,
		"next_offer_cost_q16": 163840, "reroll_cost_q16": 81920,
		"offer_active": true, "ideology_slots_capacity": 3,
		"national_spirit_slots_capacity": 1,
		"capacity_unlock_owned": PackedByteArray([1, 0]),
	}, {"ok": true, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"ideology_capacity_max": 6, "national_spirit_capacity_max": 3,
		"capacity_unlock_technology_names": PackedStringArray(["王国体系", "帝国整合"]),
		"capacity_unlock_ideology_deltas": PackedInt32Array([1, 1]),
		"capacity_unlock_spirit_deltas": PackedInt32Array([0, 1])})
	_expect("presentation uses the escalating draw cost and reroll price",
		int(escalated.get("offer_cost_q16", 0)) == 163840
		and int(escalated.get("reroll_cost_q16", 0)) == 81920
		and bool(escalated.get("can_reroll", false))
		and int(escalated.get("slots_max", 0)) == 6)
	var unlock_rows: Array = escalated.get("capacity_unlocks", [])
	_expect("presentation lists slot milestones with ownership",
		unlock_rows.size() == 2 and bool((unlock_rows[0] as Dictionary).get("owned", false))
		and not bool((unlock_rows[1] as Dictionary).get("owned", true)))
	workspace.set_model({
		"country_handle": 1,
		"current_day": 0,
		"ideology": {
			"available": true,
			"snapshot": {
				"ok": true,
				"materialized": false,
				"ideology_points_q16": 196608,
				"next_offer_cost_q16": 131072,
				"ideology_slots_used": 0,
				"ideology_slots_capacity": 3,
				"national_spirit_slots_used": 0,
				"national_spirit_slots_capacity": 2,
				"known_ids": PackedInt32Array(),
				"offer_active": false,
			},
			"catalog": {"ok": true, "ideologies": []},
		},
	})
	_expect("playable empty collection shows the draw action",
		not bool(workspace.call("offer_button_disabled"))
		and bool(workspace.call("empty_state_visible"))
		and int(workspace.call("slots_capacity")) == 3
		and not String(workspace.call("hint_text")).contains("暂不可用"))
	_expect("deck table reports catalog slot capacity",
		int(workspace.call("niche_count", 1)) == 3
		and int(workspace.call("niche_count", 2)) == 2)
	var offer_card := CountryViewModel.present_ideology_card({
		"display_name": "共同体治理",
		"detail_key": "以共同仓储组织生产。",
		"icon_key": "country.economy",
		"level_labels": PackedStringArray(["初识", "通晓", "化育"]),
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
	var badge_texts := PackedStringArray()
	for badge in offer_card.get("badges", []) as Array:
		badge_texts.append(String((badge as Dictionary).get("text", "")))
	_expect("card badges name the next level instead of doubling",
		"、".join(badge_texts).contains("通晓")
		and not "、".join(badge_texts).contains("翻倍"))
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


## Every definition a real card names has to exist in the modifier catalog.
##
## This is the link the migration to `economy.city.*` could silently break: the
## per-good / per-building / per-need definitions are GENERATED at runtime by
## modifier_catalog.gd, so a typo or a missing family member yields a card that
## compiles, applies, and does nothing -- the exact failure mode that hid the
## write-only `ideology.city.*` family for weeks.
func _test_card_definitions_resolve() -> void:
	var effects: Resource = load("res://data/ideologies/default_ideology_effects.tres")
	if not _require("default ideology effects load", effects != null):
		return
	var effect_validation := String(effects.call("validate"))
	if not _require("default ideology effects validate",
			effect_validation.is_empty(), effect_validation):
		return
	var modifier_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not _require("modifier catalog compiles", bool(modifier_ir.get("ok", false))):
		return
	var known := {}
	for key in modifier_ir.get("definition_keys", PackedStringArray()):
		known[String(key)] = true
	var missing := {}
	for effect in effects.effects:
		if effect == null:
			continue
		for command in effect.commands:
			if command == null or int(command.action) != 1:  # MODIFIER_COMMAND
				continue
			var key := String(command.definition_key)
			if key.is_empty() or not known.has(key):
				missing[key] = true
	_expect("every card modifier definition resolves (%d missing)" % missing.size(),
		missing.is_empty())


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


## `_expect` plus the condition, so a helper can bail out early. This file's
## `_expect` returns nothing; the newer tests' `_require` does -- keeping the two
## names distinct avoids a silent no-op if the older file ever gains one.
func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label if detail.is_empty() else "%s: %s" % [label, detail], condition)
	return condition


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
