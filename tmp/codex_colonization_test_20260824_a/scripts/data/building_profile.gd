class_name BuildingProfile
extends Resource

## Stable catalog identity. Runtime storage uses the sorted dense index.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export_enum("collector", "industrial", "service") var building_kind: String = "industrial"
## Explicit technology-output sector. Authoring must not infer farms from the
## generic collector kind because collectors also cover mines and fisheries.
@export_enum("agriculture", "extractive", "manufacturing", "energy", "knowledge") \
var economic_sector_id: String = ""
## Cold-path taxonomy used by data-driven selectors. Runtime compilation
## expands tags to dense building IDs; simulation loops never compare strings.
@export var semantic_tags: PackedStringArray = PackedStringArray()
## Direct unlock alternatives. At least one referenced tech.* tag must be
## completed. Non-tech taxonomy tags are ignored by the runtime gate.
@export var technology_tags: PackedStringArray = PackedStringArray()
## Supporting technology axes. Every referenced tech.* tag must be completed
## in addition to the ANY gate above. These tags deliberately do not count as
## direct content bindings in TechnologyCatalog audits.
@export var required_technology_tags: PackedStringArray = PackedStringArray()
## Optional construction-upgrade family. Existing lower-tier buildings keep
## operating, but only the highest technology-available tier may be built.
@export var upgrade_family_id: StringName = &""
@export_range(0, 255, 1) var upgrade_tier: int = 0
## Empty keeps non-biological production at the catalog baseline.
@export var production_climate_profile_id: StringName = &""

## Construction is accepted atomically at an economy sample boundary. The
## fixed delay is intentionally small-scope: no builders or staged progress.
## Empty construction goods are allowed only for zero-day service lots and for
## `starter.construction` collectors whose daily inputs are empty or all-soft.
@export_range(0, 36500, 1) var construction_days: int = 0
@export var construction_good_ids: PackedStringArray = PackedStringArray()
@export var construction_quantities: PackedInt64Array = PackedInt64Array()
## Optional construction-material alternatives. Each entry in
## construction_good_ids is a required group (AND); the corresponding
## candidate slice is an OR list. Empty arrays preserve the legacy single-good
## recipe and are expanded by EconomyCatalog.
@export var construction_candidate_offsets: PackedInt32Array = PackedInt32Array()
@export var construction_candidate_good_ids: PackedStringArray = PackedStringArray()
@export var construction_candidate_efficiency_q16: PackedInt32Array = PackedInt32Array()

## V1 has exactly one owner profession. Ownership itself is held by the
## sponsoring (cell, signature) cohort identity and survives handle churn.
@export var owner_profession_id: StringName = &""
@export_range(1, 1000000, 1) var owner_slots_per_building: int = 1
@export var employee_profession_ids: PackedStringArray = PackedStringArray()
@export var employee_slots_per_building: PackedInt64Array = PackedInt64Array()
## Parallel role-level wage columns. Empty arrays accept the legacy type-level
## fields below so v7 content remains loadable during migration.
@export var employee_wage_policy_ids: PackedStringArray = PackedStringArray()
@export var employee_reference_wages_per_day: PackedInt64Array = PackedInt64Array()

## Quantities are per building per simulation day in GOODS_SCALE (1000).
@export var input_good_ids: PackedStringArray = PackedStringArray()
@export var input_quantities_per_day: PackedInt64Array = PackedInt64Array()
## Parallel Q16 hardness per input slot. Empty preserves legacy fully hard inputs.
## 65536 means missing stock stops production; 0 means the input is purely optional;
## intermediate values leave a baseline output floor when the input is missing.
@export var input_required_q16: PackedInt32Array = PackedInt32Array()
## Optional parallel input constraints. Empty category IDs preserve exact-good
## recipes. A category input accepts every technology-available good in that
## category whose production quality meets the minimum; its good-level Q16
## efficiency determines physical consumption.
@export var input_category_ids: PackedStringArray = PackedStringArray()
@export var input_min_quality_levels: PackedInt32Array = PackedInt32Array()
## Optional profile-local CSR for recipe-specific substitutes. A non-empty
## candidate slice is mutually exclusive with the category on that input slot.
## Efficiencies are Q16 effective recipe quantity per physical good quantity.
@export var input_candidate_offsets: PackedInt32Array = PackedInt32Array([0])
@export var input_candidate_good_ids: PackedStringArray = PackedStringArray()
@export var input_candidate_efficiency_q16: PackedInt32Array = PackedInt32Array()
@export var output_good_ids: PackedStringArray = PackedStringArray()
@export var output_quantities_per_day: PackedInt64Array = PackedInt64Array()
## Price V4 supply response. The optional output cost shares must align with
## output_good_ids and sum to Q16; an empty array uses reference-value shares.
@export_range(0, 262144, 1) var target_operating_margin_q16: int = 9830
@export_range(0, 262144, 1) var supply_price_elasticity_q16: int = 65536
@export var output_cost_shares_q16: PackedInt32Array = PackedInt32Array()
@export var resource_ids: PackedStringArray = PackedStringArray()
## Resource reserve units and output good units are intentionally independent.
## Their ratio is the extractor's content-level efficiency and may differ by
## technology, collection method, resource type, and co-product recipe.
@export var resource_quantities_per_day: PackedInt64Array = PackedInt64Array()
## Parallel to resource_ids. extract quantities are per building/day and are
## removed from the local reserve; capacity quantities are required per
## building, constrain output, and are never removed or multiplied by dt.
@export var resource_interaction_modes: PackedStringArray = PackedStringArray()
## Parallel to resource_ids. All production resources are local: extraction and
## capacity checks read only the building cell's reserve.
@export var resource_access_modes: PackedStringArray = PackedStringArray()
@export var resource_generation_ids: PackedStringArray = PackedStringArray()
@export var resource_generation_quantities_per_day: PackedInt64Array = PackedInt64Array()
@export_range(0, 65536, 1) var resource_generation_floor_q16: int = 0

## Native behavior registry. `none` runs a goods-only recipe;
## `consume_local_resources` consumes resource columns; `cultivate_local_resources`
## additionally publishes the generation columns for a later resource pass.
@export_enum("none", "consume_local_resources", "cultivate_local_resources") var behavior_id: String = "none"
@export_range(1, 1, 1) var behavior_version: int = 1

## Postfix condition bytecode. Every token uses aligned columns.
## opcodes: 1=PREDICATE, 2=AND, 3=OR, 4=NOT.
## signals: 0=temp, 1=moisture, 2=snow, 3=weather, 4=elevation,
##          5=terrain, 6=landform, 7=vegetation, 8=is_water,
##          9=has_river, 10=natural_resource.
## compares: 0===, 1=!=, 2=<, 3=<=, 4=>, 5=>=.
## Values use Q16 for float signals and GOODS_SCALE for natural resources.
@export var condition_opcodes: PackedInt32Array = PackedInt32Array()
@export var condition_signals: PackedInt32Array = PackedInt32Array()
@export var condition_compares: PackedInt32Array = PackedInt32Array()
@export var condition_reference_ids: PackedStringArray = PackedStringArray()
@export var condition_values: PackedInt64Array = PackedInt64Array()

## Legacy v7 type-level wage ABI. New content should use the parallel role
## columns above. `adaptive` seeds each role from this reference wage.
@export_enum("none", "fixed", "adaptive") var wage_policy_id: String = "none"
@export_range(0, 1000000000000, 1) var wage_per_employee_per_day: int = 0
