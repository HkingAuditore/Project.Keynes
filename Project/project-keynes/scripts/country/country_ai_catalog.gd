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
@export_range(1, 10000, 1) var colonize_population_share_bp: int = 2500
## The economy rejects kits below 3 owner slots (COLONIZATION_KIT_MIN_OWNER_SLOTS).
@export_range(3, 100000, 1) var colonize_min_population: int = 3
@export_range(1, 16, 1) var colonize_vision_radius: int = 3
@export_range(1, 16, 1) var colonize_target_ring: int = 2
@export_range(0, 3650, 1) var colonize_failure_cooldown_days: int = 120
@export_range(0, 3650, 1) var colonize_min_reserve_days: int = 180

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
