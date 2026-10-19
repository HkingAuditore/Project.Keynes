class_name EffectDefinition
extends Resource

@export var key: StringName = &""
@export var version: int = 1
@export_range(1, 3650, 1) var cadence_days: int = 1
@export_range(1, 1000000, 1) var max_work: int = 1024
@export var enabled: bool = true
@export var behavior_id: StringName = &""
@export var conditions: Array[Resource] = []
@export var instructions: Array[Resource] = []
@export var commands: Array[Resource] = []

## Optional declarative metadata. Existing technology/trigger/person
## definitions keep the neutral defaults; family effects use these columns to
## declare ownership, target domain and lifecycle without adding a script
## callback to the native evaluation loop.
@export var source_kind: int = 0
@export var target_domain: int = 0
@export var operation: int = 0
@export var lifecycle: int = 0
@export var duration_days: int = -1
@export var stack_policy: int = 0
@export var stack_key: StringName = &""
@export_range(1, 65536, 1) var max_stacks: int = 1
@export var priority: int = 0
@export var target_selector_kind: int = 0
@export var target_selector_id: StringName = &""
## [0] = cell cap for the generalised selectors (0 means "use the runtime
## default"), [1] = terrain id / resource id / predicate id. Only read when
## target_selector_kind >= 8; otherwise both stay 0 and cost nothing.
@export var target_selector_param: PackedInt32Array = PackedInt32Array()
## Declares that this program owns a reconciled Effect instance (conditions,
## lifecycle, stack policy, per-target fan-out). Compiled into `managed_flags`.
## Family and ideology effects set it; technology/trigger/person programs leave
## it false and keep the one-shot command path.
@export var managed: bool = false
@export var magnitude_by_prestige_q16: PackedInt32Array = PackedInt32Array()
