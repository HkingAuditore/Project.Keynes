class_name IdeologyAffinity
extends Resource

## Soft draw-weight bias for one idea. The gate is a boolean maintained by
## IdeologyContextService (geo.* / dev.* vocabulary); while it holds, the draw
## weight is multiplied by multiplier_bp / 10000.
##
## Affinity never removes a card from the pool: 0 is treated as "no bonus", not
## as a veto. Hard availability is expressed through draw_requirements instead.
@export var gate_key: String = ""
@export_range(0, 20000, 1) var multiplier_bp: int = 10000

const MAX_MULTIPLIER_BP := 20000


func validate() -> String:
	if gate_key.strip_edges().is_empty():
		return "ideology_affinity_gate_empty"
	if multiplier_bp < 0 or multiplier_bp > MAX_MULTIPLIER_BP:
		return "ideology_affinity_multiplier_invalid"
	return ""
