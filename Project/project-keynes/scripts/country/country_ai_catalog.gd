class_name CountryAiCatalog
extends Resource

## Data-driven foreign-country AI catalog.  `compile_native_catalog()` turns
## this resource into the flat dictionary accepted by
## `DCWorldExt.configure_country_ai`; the native side validates it and derives
## the catalog hash that PKSV `pkai` checks on restore.

const DEFAULT_PATH := "res://data/country/default_country_ai.tres"
const MODE_ENV := "PK_COUNTRY_AI_MODE"
const DIFFICULTY_ENV := "PK_COUNTRY_AI_DIFFICULTY"
## Offline tuning only: absolute or res:// path to a candidate catalog. A
## different catalog changes the native catalog hash, so PKSV pkai saves made
## with it will not restore against the default catalog.
const CATALOG_PATH_ENV := "PK_COUNTRY_AI_CATALOG"

const AGENDA_IDS := ["develop", "expand", "accumulate", "era_push", "stabilize"]
const INPUT_IDS := ["reserve_days", "satisfaction_q16", "frontier_cells", "milestone_gap",
	"territory_cells", "essentials_q16", "expeditions", "cash_trend_bp"]
const CURVE_IDS := ["linear", "quadratic", "inv_quadratic", "smoothstep", "step"]
const DOMAIN_IDS := ["agriculture", "engineering", "science", "society"]
const TAX_KIND_COUNT := 5
const FAMILY_PREF_IDS := ["margin", "revenue", "founders", "jitter"]
const Q16 := 65536

@export_enum("OFF", "PROBE", "ACTIVE") var mode: String = "ACTIVE"
## easy: more noise, slower cadence, conservative budgets.  hard: the reverse.
## The AI never receives extra resources at any difficulty.
@export_enum("easy", "normal", "hard") var difficulty: String = "normal"

@export_group("Cadence")
@export_range(1, 90, 1) var think_days: int = 5
@export_range(1, 720, 1) var strategy_days: int = 30
@export_range(1, 360, 1) var research_days: int = 10
@export_range(1, 720, 1) var tax_days: int = 30
@export_range(1, 720, 1) var colonize_days: int = 45
@export_range(0, 3650, 1) var agenda_min_days: int = 90
@export_range(0, 10000, 1) var agenda_inertia_bp: int = 1500
@export_range(0, 5000, 1) var decision_noise_bp: int = 500

@export_group("Research")
@export_range(1, 3650, 1) var research_budget_horizon_days: int = 360
@export var research_min_daily_budget: int = 0
## 0 means no cap.
@export var research_max_daily_budget: int = 0
@export_range(0, 20000, 1) var research_weight_threshold_bp: int = 1500
@export_range(1, 32, 1) var research_max_enqueue_per_eval: int = 3
@export_range(0, 10000, 1) var research_budget_change_bp: int = 2500
@export_range(1, 4096, 1) var research_frontier_visit_limit: int = 256
## Daily budget cap = household tax revenue x share + population x per-capita
## allowance. Procurement is paid from the treasury, so without this cap a large
## treasury floods merchants with cash and prices outrun household incomes.
@export_range(0, 10000, 1) var research_tax_share_bp: int = 3500
@export var research_per_capita_budget: int = 0
## No procurement while population-weighted essentials satisfaction is below this.
@export_range(0.0, 1.0, 0.01) var research_essentials_floor: float = 0.90
## Food before research: the budget is full up to the first carrying load,
## falls linearly to zero at the second, and stops while the hungry share
## (essentials below 0.9) reaches the maximum.
@export_range(0.0, 4.0, 0.01) var research_load_full: float = 0.50
@export_range(0.0, 4.0, 0.01) var research_load_zero: float = 0.85
@export_range(0.0, 1.0, 0.01) var research_hungry_share_max: float = 0.06

@export_group("Tax")
## Bit mask over income(0), consumption(1), business(2), and reserved kinds.
@export var tax_kind_mask: int = 0x7
@export_range(1, 2000, 1) var tax_step_bp: int = 100
@export_range(1, 2000, 1) var tax_max_step_bp: int = 300
@export_range(0.0, 0.5, 0.005) var tax_deadband: float = 0.05
@export_range(0.0, 1.0, 0.01) var satisfaction_floor: float = 0.5
@export_range(1, 3650, 1) var reserve_target_days: int = 360
@export var reserve_floor_cash: int = 0

@export_group("Colonization")
@export_range(0, 16, 1) var colonize_max_in_flight: int = 1
## Share of a family's local surplus sent on each expedition (basis points).
## Tiny parties never staff a colony; half the surplus matches a real town seed.
@export_range(1, 10000, 1) var colonize_population_share_bp: int = 5000
## AI floor above the economy kit minimum (3). Starter settlements are ~20.
@export_range(3, 100000, 1) var colonize_min_population: int = 20
@export_range(1, 16, 1) var colonize_vision_radius: int = 3
@export_range(1, 16, 1) var colonize_target_ring: int = 2
@export_range(0, 3650, 1) var colonize_failure_cooldown_days: int = 120
@export_range(0, 3650, 1) var colonize_min_reserve_days: int = 180
## Expeditions carry away part of a family: wait until the homeland is large,
## dense and well fed, otherwise every colony shrinks the country.
@export_range(0, 100000, 1) var colonize_min_country_population: int = 150
@export_range(0, 100000, 1) var colonize_min_population_per_cell: int = 80
@export_range(0.0, 1.0, 0.01) var colonize_essentials_floor: float = 0.97
## Target cells scoring below this habitability (0..1) are never colonized.
@export_range(0.0, 1.0, 0.01) var colonize_min_cell_value: float = 0.0
@export_range(0, 100000, 1) var colonize_cell_value_weight_bp: int = 20000
## No expedition while more than this share of the population is hungry.
@export_range(0.0, 1.0, 0.01) var colonize_hungry_share_max: float = 0.03

@export_group("Food subsidy")
## Negative business-tax override on survival-food building types; 0 disables.
@export_range(-100000, 0, 1) var subsidy_food_rate_bp: int = -3000
## Switched on at the first hungry share, off again at the second.
@export_range(0.0, 1.0, 0.01) var subsidy_on_hungry_share: float = 0.06
@export_range(0.0, 1.0, 0.01) var subsidy_off_hungry_share: float = 0.02

@export_group("Agendas and personalities")
## Exactly one entry per AGENDA_IDS id.  Each consideration:
## {input, curve, x0, x1, y0, y1}; y values are 0..1 floats.
@export var agendas: Array[Dictionary] = []
## Up to 16 entries.  Arrays: agenda_bias (5, multiplier), domain_affinity
## (4, multiplier), tax_min/tax_max/tax_initial (5, percent), family_pref (4).
@export var personalities: Array[Dictionary] = []


static func load_default() -> CountryAiCatalog:
	var override_path := OS.get_environment(CATALOG_PATH_ENV).strip_edges()
	if not override_path.is_empty():
		var override_catalog := ResourceLoader.load(
			override_path, "", ResourceLoader.CACHE_MODE_IGNORE) as CountryAiCatalog
		if override_catalog != null:
			return override_catalog
		push_warning("[country-ai] %s=%s did not load; using default catalog" % [
			CATALOG_PATH_ENV, override_path])
	return load(DEFAULT_PATH) as CountryAiCatalog


## Returns {ok, reason?, catalog?}.  `seed` makes personality assignment and
## decision noise reproducible per world; env overrides are for headless A/B.
func compile_native_catalog(seed: int) -> Dictionary:
	var resolved_mode := mode
	var env_mode := OS.get_environment(MODE_ENV).strip_edges().to_upper()
	if env_mode in ["OFF", "PROBE", "ACTIVE"]:
		resolved_mode = env_mode
	var resolved_difficulty := difficulty
	var env_difficulty := OS.get_environment(DIFFICULTY_ENV).strip_edges().to_lower()
	if env_difficulty in ["easy", "normal", "hard"]:
		resolved_difficulty = env_difficulty
	var noise_scale := 1.0
	var cadence_scale := 1.0
	var reserve_scale := 1.0
	match resolved_difficulty:
		"easy":
			noise_scale = 2.5
			cadence_scale = 1.5
			reserve_scale = 1.5
		"hard":
			noise_scale = 0.4
			cadence_scale = 0.75
			reserve_scale = 0.75
	var out := {
		"schema": 1,
		"mode": resolved_mode,
		"difficulty": resolved_difficulty,
		"seed": seed,
		"think_days": maxi(1, roundi(think_days * cadence_scale)),
		"strategy_days": maxi(1, roundi(strategy_days * cadence_scale)),
		"research_days": maxi(1, roundi(research_days * cadence_scale)),
		"tax_days": maxi(1, roundi(tax_days * cadence_scale)),
		"colonize_days": maxi(1, roundi(colonize_days * cadence_scale)),
		"agenda_min_days": agenda_min_days,
		"agenda_inertia_bp": agenda_inertia_bp,
		"decision_noise_bp": clampi(roundi(decision_noise_bp * noise_scale), 0, 5000),
		"research_budget_horizon_days": research_budget_horizon_days,
		"research_min_daily_budget": research_min_daily_budget,
		"research_max_daily_budget": research_max_daily_budget,
		"research_weight_threshold_bp": research_weight_threshold_bp,
		"research_max_enqueue_per_eval": research_max_enqueue_per_eval,
		"research_budget_change_bp": research_budget_change_bp,
		"research_frontier_visit_limit": research_frontier_visit_limit,
		"research_tax_share_bp": research_tax_share_bp,
		"research_per_capita_budget": research_per_capita_budget,
		"research_essentials_floor_q16": roundi(research_essentials_floor * Q16),
		"tax_kind_mask": tax_kind_mask,
		"tax_step_bp": tax_step_bp,
		"tax_max_step_bp": tax_max_step_bp,
		"tax_deadband_q16": roundi(tax_deadband * Q16),
		"satisfaction_floor_q16": roundi(satisfaction_floor * Q16),
		"reserve_target_days": maxi(1, roundi(reserve_target_days * reserve_scale)),
		"reserve_floor_cash": reserve_floor_cash,
		"colonize_max_in_flight": colonize_max_in_flight,
		"colonize_population_share_bp": colonize_population_share_bp,
		"colonize_min_population": colonize_min_population,
		"colonize_vision_radius": colonize_vision_radius,
		"colonize_target_ring": colonize_target_ring,
		"colonize_failure_cooldown_days": colonize_failure_cooldown_days,
		"colonize_min_reserve_days": maxi(0, roundi(colonize_min_reserve_days * reserve_scale)),
		"colonize_min_country_population": colonize_min_country_population,
		"colonize_min_population_per_cell": colonize_min_population_per_cell,
		"colonize_essentials_floor_q16": roundi(colonize_essentials_floor * Q16),
		"colonize_min_cell_value_q16": maxi(1, roundi(colonize_min_cell_value * Q16)),
		"colonize_cell_value_weight_bp": colonize_cell_value_weight_bp,
		"research_load_full_q16": roundi(research_load_full * Q16),
		"research_load_zero_q16": roundi(research_load_zero * Q16),
		"research_hungry_share_max_q16": roundi(research_hungry_share_max * Q16),
		"colonize_hungry_share_max_q16": roundi(colonize_hungry_share_max * Q16),
		"subsidy_food_rate_bp": subsidy_food_rate_bp,
		"subsidy_on_hungry_share_q16": roundi(subsidy_on_hungry_share * Q16),
		"subsidy_off_hungry_share_q16": roundi(subsidy_off_hungry_share * Q16),
	}
	var agenda_rows: Array = []
	var seen := {}
	for source in agendas:
		var id := String(source.get("id", ""))
		if not AGENDA_IDS.has(id) or seen.has(id):
			return {"ok": false, "reason": "country_ai_agenda_id_invalid", "id": id}
		seen[id] = true
		var considerations: Array = []
		for raw in source.get("considerations", []):
			var c: Dictionary = raw
			var input := INPUT_IDS.find(String(c.get("input", "")))
			var curve := CURVE_IDS.find(String(c.get("curve", "linear")))
			if input < 0 or curve < 0:
				return {"ok": false, "reason": "country_ai_consideration_invalid", "id": id}
			var scale := Q16 if INPUT_IDS[input].ends_with("_q16") else 1
			considerations.append({
				"input": input,
				"curve": curve,
				"x0": roundi(float(c.get("x0", 0.0)) * scale),
				"x1": roundi(float(c.get("x1", 1.0)) * scale),
				"y0_q16": roundi(float(c.get("y0", 0.0)) * Q16),
				"y1_q16": roundi(float(c.get("y1", 1.0)) * Q16),
			})
		agenda_rows.append({
			"id": id,
			"considerations": considerations,
			"research_share_bp": int(source.get("research_share_bp", 3000)),
			"expansion_slots": int(source.get("expansion_slots", 0)),
			"tax_bias_bp": int(source.get("tax_bias_bp", 0)),
			"satisfaction_floor_shift_q16": roundi(float(source.get("satisfaction_floor_shift", 0.0)) * Q16),
			"era_focus": 1 if bool(source.get("era_focus", false)) else 0,
		})
	if agenda_rows.size() != AGENDA_IDS.size():
		return {"ok": false, "reason": "country_ai_agenda_count_invalid"}
	out["agendas"] = agenda_rows
	var personality_rows: Array = []
	for source in personalities:
		var id := String(source.get("id", ""))
		if id.is_empty():
			return {"ok": false, "reason": "country_ai_personality_id_missing"}
		var row := {
			"id": id,
			"weight": int(source.get("weight", 1)),
			"risk_bp": roundi(float(source.get("risk", 0.5)) * 10000.0),
		}
		var arrays := {
			"agenda_bias_bp": [source.get("agenda_bias", []), AGENDA_IDS.size(), 10000.0, 1.0],
			"domain_affinity_bp": [source.get("domain_affinity", []), DOMAIN_IDS.size(), 10000.0, 1.0],
			"tax_min_bp": [source.get("tax_min", []), TAX_KIND_COUNT, 100.0, 0.0],
			"tax_max_bp": [source.get("tax_max", []), TAX_KIND_COUNT, 100.0, 0.0],
			"tax_initial_bp": [source.get("tax_initial", []), TAX_KIND_COUNT, 100.0, 0.0],
			"family_pref": [source.get("family_pref", [1.0, 0.3, 0.2, 0.1]), FAMILY_PREF_IDS.size(), 10000.0, 0.0],
		}
		for key in arrays:
			var spec: Array = arrays[key]
			var values: Array = spec[0]
			var count: int = spec[1]
			var packed := PackedInt32Array()
			for i in range(count):
				var value: float = float(values[i]) if i < values.size() else float(spec[3])
				packed.append(roundi(value * float(spec[2])))
			row[key] = packed
		personality_rows.append(row)
	if personality_rows.is_empty():
		return {"ok": false, "reason": "country_ai_personalities_invalid"}
	out["personalities"] = personality_rows
	return {"ok": true, "catalog": out}
