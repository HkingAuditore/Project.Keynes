class_name FamilyModifierEffect
extends Resource

enum Target {
	ECONOMY_CELL_GROUP = 0,
	CLIMATE_CELL_ENTITY = 1,
}

@export var definition_key: StringName = &""
@export_enum("EconomyCellGroup", "ClimateCellEntity") var target: int = Target.ECONOMY_CELL_GROUP
## Six Q16 entries for prestige levels 0..V. Zero disables the effect at that level.
@export var tier_magnitude_q16: PackedInt32Array = PackedInt32Array([
	0, 16384, 32768, 49152, 65536, 81920,
])

