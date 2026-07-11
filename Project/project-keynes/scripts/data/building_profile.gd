class_name BuildingProfile
extends Resource

## Stable catalog identity. Runtime storage uses the sorted dense index.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null

## Construction is accepted atomically at an economy sample boundary. The
## fixed delay is intentionally small-scope: no builders or staged progress.
@export_range(0, 36500, 1) var construction_days: int = 0
@export var construction_good_ids: PackedStringArray = PackedStringArray()
@export var construction_quantities: PackedInt64Array = PackedInt64Array()

## V1 has exactly one owner profession. Ownership itself is held by the
## sponsoring (cell, signature) cohort identity and survives handle churn.
@export var owner_profession_id: StringName = &""
@export_range(1, 1000000, 1) var owner_slots_per_building: int = 1
@export var employee_profession_ids: PackedStringArray = PackedStringArray()
@export var employee_slots_per_building: PackedInt64Array = PackedInt64Array()

## Quantities are per building per simulation day in GOODS_SCALE (1000).
@export var input_good_ids: PackedStringArray = PackedStringArray()
@export var input_quantities_per_day: PackedInt64Array = PackedInt64Array()
@export var output_good_ids: PackedStringArray = PackedStringArray()
@export var output_quantities_per_day: PackedInt64Array = PackedInt64Array()
@export var resource_ids: PackedStringArray = PackedStringArray()
@export var resource_quantities_per_day: PackedInt64Array = PackedInt64Array()

## Native behavior registry. `none` runs a goods-only recipe;
## `consume_local_resources` additionally consumes the resource columns above.
@export_enum("none", "consume_local_resources") var behavior_id: String = "none"
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

## Temporary wage ABI. `fixed` pays this amount per filled employee per day;
## the owner cohort pays at settlement and available cash caps the transfer.
@export_enum("none", "fixed") var wage_policy_id: String = "none"
@export_range(0, 1000000000000, 1) var wage_per_employee_per_day: int = 0
