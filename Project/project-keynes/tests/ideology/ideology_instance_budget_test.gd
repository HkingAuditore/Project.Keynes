extends SceneTree

## L0-3 acceptance: the declaration budget and the concurrency budget are two
## different quantities, and both are now enforced by name.
##
## Why this exists
## ---------------
## `max_effect_instances` counted card effect rows across the WHOLE catalog
## (card x level x row). The number the runtime actually refuses past --
## `EffectRuntime::_max_instances` -- counts live per-country instances, which
## is a function of slots and per-program target fan-out. One field was being
## read as the other.
##
## The practical consequence ran one way: raising the row budget to fit a 179-card
## pool said nothing at all about whether 9 slots x 32 cells fits in memory, and
## a catalog that passed the row check could still overflow the instance table.
##
## What is pinned here
## -------------------
##  1. Both numbers are published on the compiled catalog, and they are derived
##     from different inputs.
##  2. Each budget can fail on its own while the other is generous -- otherwise
##     "two budgets" would just be one budget with two names.
##  3. Per-card worst case is the card's WIDEST LEVEL, not the sum over levels:
##     only one level is live at a time, so summing would report a ceiling three
##     times too high.
##  4. A program's own cell cap is used when it declares one, and the runtime's
##     `SELECTOR_MAX_CELLS` when it does not -- no third literal anywhere.
##  5. The slot count uses the GROWN capacities, because the budget has to
##     survive a save that unlocked both slot technologies.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyLevelDefinitionScript = preload(
	"res://scripts/ideology/ideology_level_definition.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")

## Mirrors `IdeologyEffectDefinition.TargetSelectorKind` without importing the
## enum into a const initialiser (see effect_selector_tag_resolution_test.gd).
var CELL_DOMAIN: int = IdeologyEffectDefinitionScript.TargetDomain.SETTLEMENT_CELL
var COUNTRY_DOMAIN: int = IdeologyEffectDefinitionScript.TargetDomain.COUNTRY
var SELECTOR_DISTANCE_N: int = IdeologyEffectDefinitionScript.TargetSelectorKind.DISTANCE_N
var SELECTOR_OWNER: int = IdeologyEffectDefinitionScript.TargetSelectorKind.OWNER
var MAX_CELLS: int = IdeologyEffectDefinitionScript.SELECTOR_MAX_CELLS

var _checks := 0
var _failures := 0
var _economy: Dictionary = {}


func _init() -> void:
	_run()
	print("ideology instance budget: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_economy = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for the budget cases",
		bool(_economy.get("ok", false)), str(_economy.get("reason", "")))
	if not bool(_economy.get("ok", false)):
		return
	# Built before the first case reads them: an argument is evaluated before
	# `_compile` runs, so lazily initialising inside the callee would hand the
	# first caller a null program.
	_wide_program = _make_program(&"wide", CELL_DOMAIN, SELECTOR_DISTANCE_N, 0)
	_country_program = _make_program(&"country", COUNTRY_DOMAIN, SELECTOR_OWNER, 0)
	_test_wide_program_reports_fanout()
	_test_declaration_budget_is_independent()
	_test_concurrency_budget_is_independent()
	_test_widest_level_not_sum()
	_test_declared_cell_cap_is_used()
	_test_grown_slots_are_counted()


## 1. A per-cell fan-out program is the multiplicand. Country programs are not.
func _test_wide_program_reports_fanout() -> void:
	var wide := _compile(1, _wide_program, _profile())
	_expect("a wide catalog compiles", bool(wide.get("ok", false)),
		str(wide.get("reason", "")))
	if bool(wide.get("ok", false)):
		_expect("the fan-out program is counted at the runtime cell cap",
			int(wide.get("max_instances_per_card", 0)) == MAX_CELLS,
			str(wide.get("max_instances_per_card", 0)))
		_expect("slots are base ideology + base national spirit",
			int(wide.get("concurrency_slots", 0)) == 9,
			str(wide.get("concurrency_slots", 0)))
		_expect("worst case is slots x per-card",
			int(wide.get("worst_case_concurrent_instances", 0)) == 9 * MAX_CELLS,
			str(wide.get("worst_case_concurrent_instances", 0)))
		_expect("the declaration count is reported separately",
			int(wide.get("declared_effect_instances", -1)) == 1,
			str(wide.get("declared_effect_instances", -1)))

	var narrow := _compile(1, _country_program, _profile())
	_expect("a country-domain program compiles", bool(narrow.get("ok", false)),
		str(narrow.get("reason", "")))
	if bool(narrow.get("ok", false)):
		_expect("a country-domain program costs exactly one instance",
			int(narrow.get("max_instances_per_card", 0)) == 1,
			str(narrow.get("max_instances_per_card", 0)))


## 2. Declaration side fails alone. The concurrency budget is left generous so
##    the only thing that can reject this catalog is the row count.
func _test_declaration_budget_is_independent() -> void:
	var profile := _profile()
	profile.max_effect_instances = 0
	profile.max_concurrent_instances = 4096
	var result := _compile(1, _wide_program, profile)
	_expect("a zero row budget rejects a catalog that declares a row",
		not bool(result.get("ok", false)))
	_expect("the rejection is the declaration budget, not concurrency",
		String(result.get("reason", "")) == "ideology_effect_instance_limit_exceeded",
		str(result.get("reason", "")))


## 3. Concurrency side fails alone: rows fit easily, the fan-out does not.
func _test_concurrency_budget_is_independent() -> void:
	var profile := _profile()
	profile.max_effect_instances = 2048
	profile.max_concurrent_instances = 9 * MAX_CELLS - 1
	var result := _compile(1, _wide_program, profile)
	_expect("a too-small concurrency budget rejects the catalog",
		not bool(result.get("ok", false)))
	var reason := String(result.get("reason", ""))
	_expect("the rejection names the concurrency budget",
		reason.begins_with("ideology_concurrent_instance_limit_exceeded:"), reason)
	# The message carries both numbers and the decomposition. A bare `false`
	# cannot tell an author whether to shrink the card or raise the budget.
	_expect("the rejection carries the numbers and the slot decomposition",
		reason == "ideology_concurrent_instance_limit_exceeded:%d>%d:9x%d" % [
			9 * MAX_CELLS, 9 * MAX_CELLS - 1, MAX_CELLS], reason)
	# Exactly at the limit must pass: an off-by-one here would reject a catalog
	# that fits, which is the failure mode that makes people raise budgets.
	profile.max_concurrent_instances = 9 * MAX_CELLS
	_expect("a catalog exactly at the budget compiles",
		bool(_compile(1, _wide_program, profile).get("ok", false)))


## 4. Level shape. Level 0 has one wide row, level 1 has two: the card's worst
##    case is 2 x cap, not 3 x cap.
func _test_widest_level_not_sum() -> void:
	var rows := [1, 2, 0]
	var result := _compile(rows.size(), _wide_program, _profile(), rows)
	_expect("a multi-level card compiles", bool(result.get("ok", false)),
		str(result.get("reason", "")))
	if bool(result.get("ok", false)):
		_expect("the widest level is used, not the sum over levels",
			int(result.get("max_instances_per_card", 0)) == 2 * MAX_CELLS,
			str(result.get("max_instances_per_card", 0)))
		_expect("the declaration count still sums every level's rows",
			int(result.get("declared_effect_instances", -1)) == 3,
			str(result.get("declared_effect_instances", -1)))


## 5. A program that declares its own cap is not silently floored at 32.
func _test_declared_cell_cap_is_used() -> void:
	var program := _make_program(&"capped", CELL_DOMAIN, SELECTOR_DISTANCE_N, 4)
	var result := _compile(1, program, _profile())
	_expect("a capped program compiles", bool(result.get("ok", false)),
		str(result.get("reason", "")))
	if bool(result.get("ok", false)):
		_expect("the program's own cell cap is the multiplicand",
			int(result.get("max_instances_per_card", 0)) == 4,
			str(result.get("max_instances_per_card", 0)))
	# A single-target selector inside a per-cell domain is one instance even
	# though the domain fans out: the selector is what decides.
	var single := _make_program(&"single", CELL_DOMAIN, SELECTOR_OWNER, 0)
	var single_result := _compile(1, single, _profile())
	if bool(single_result.get("ok", false)):
		_expect("a single-target selector costs one instance in a fan-out domain",
			int(single_result.get("max_instances_per_card", 0)) == 1,
			str(single_result.get("max_instances_per_card", 0)))


## 6. Slot count follows the grown capacities, not the starting ones.
func _test_grown_slots_are_counted() -> void:
	var profile := _profile()
	profile.ideology_capacity = 6
	profile.ideology_capacity_max = 8
	profile.national_spirit_capacity = 3
	profile.national_spirit_capacity_max = 4
	profile.max_concurrent_instances = 4096
	var result := _compile(1, _wide_program, profile)
	_expect("a grown-capacity catalog compiles", bool(result.get("ok", false)),
		str(result.get("reason", "")))
	if bool(result.get("ok", false)):
		_expect("grown slots are 8 + 4", int(result.get("concurrency_slots", 0)) == 12,
			str(result.get("concurrency_slots", 0)))
		_expect("worst case uses the grown slot count",
			int(result.get("worst_case_concurrent_instances", 0)) == 12 * MAX_CELLS,
			str(result.get("worst_case_concurrent_instances", 0)))
	# And the budget must bind on the grown number: a budget that fits the base
	# slots but not the grown ones has to be rejected.
	profile.max_concurrent_instances = 9 * MAX_CELLS
	var rejected := _compile(1, _wide_program, profile)
	_expect("a budget that only fits the base slots is rejected",
		not bool(rejected.get("ok", false)))
	_expect("the rejection reports the grown slot count",
		String(rejected.get("reason", "")).ends_with(":12x%d" % MAX_CELLS),
		str(rejected.get("reason", "")))


func _profile() -> Resource:
	var profile := IdeologyProfileScript.new()
	profile.max_effect_instances = 2048
	profile.max_concurrent_instances = 4096
	return profile


## Compiles a one-card catalog whose levels carry `rows_per_level[i]` program
## rows. `_wide_program` / `_country_program` are the two default programs; a
## caller may pass a custom one instead.
var _wide_program: Resource
var _country_program: Resource


func _compile(level_count: int, program: Resource, profile: Resource,
		rows_per_level: Array = []) -> Dictionary:
	var programs: Resource = IdeologyEffectCatalogScript.new()
	var program_list: Array[Resource] = [program]
	programs.effects = program_list
	var card: Resource = IdeologyDefinitionScript.new()
	card.id = &"probe_card"
	card.route_tag = &"probe"
	var levels: Array[Resource] = []
	for index in maxi(level_count, 1):
		var level: Resource = IdeologyLevelDefinitionScript.new()
		level.understanding_threshold_q16 = index * 65536
		var rows := int(rows_per_level[index]) if index < rows_per_level.size() else 1
		var effects: Array[Resource] = []
		for _row in rows:
			effects.append(_card_row(program.definition_key))
		level.persistent_effects = effects
		levels.append(level)
	card.levels = levels
	var catalog: Resource = IdeologyCatalogScript.new()
	catalog.profile = profile
	var definition_list: Array[Resource] = [card]
	var synergy_list: Array[Resource] = []
	catalog.definitions = definition_list
	catalog.synergies = synergy_list
	catalog.effect_programs = programs
	return catalog.compile_native_catalog(_economy, _economy)


## Authoring row that routes to `definition_key`. Only the two key fields matter
## to the compiler; everything else is inert on the program-owned path.
func _card_row(definition_key: StringName) -> Resource:
	var row := EffectCommandScript.new()
	row.action = 1
	row.domain = 1
	row.opcode = 1
	row.target_resolver = 1
	row.value_mode = 1
	row.value_q16 = 104858
	row.duration_days = -1
	row.stacks = 1
	row.command_key = &"ideology.persistent"
	row.definition_key = definition_key
	return row


func _make_program(key: StringName, domain: int, selector: int,
		cell_cap: int) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = key
	program.target_domain = domain
	program.operation = 1
	program.lifecycle = 0
	program.duration_days = -1
	program.stack_policy = 0
	program.stack_key = key
	program.max_stacks = 1
	program.target_selector_kind = selector
	program.target_selector_param = PackedInt32Array([cell_cap, 0])
	program.cadence_days = 1
	var instruction: Resource = EffectInstructionScript.new()
	instruction.op = 1
	instruction.value_q16 = 104858
	var instruction_list: Array[Resource] = [instruction]
	var command_list: Array[Resource] = [_card_row(key)]
	program.instructions = instruction_list
	program.commands = command_list
	return program


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
