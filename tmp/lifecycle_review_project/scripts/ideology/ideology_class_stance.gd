class_name IdeologyClassStance
extends Resource

@export var class_id: StringName = &"general"
@export_range(-65536, 65536, 1) var adopt_stance_q16: int = 0
@export_range(-65536, 65536, 1) var repeal_stance_q16: int = 0
@export_range(-65536, 65536, 1) var promote_stance_q16: int = 0
## -65537 disables the critical-class floor for that direction.
@export_range(-65537, 65536, 1) var adopt_min_support_q16: int = -65537
@export_range(-65537, 65536, 1) var repeal_min_support_q16: int = -65537
@export_range(-65537, 65536, 1) var promote_min_support_q16: int = -65537


func validate() -> String:
	if class_id == &"":
		return "ideology_stance_class_empty"
	return ""
