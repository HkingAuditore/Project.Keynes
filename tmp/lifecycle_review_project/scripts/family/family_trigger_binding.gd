class_name FamilyTriggerBinding
extends Resource

enum RewardTarget {
	FAMILY_BRANCH = 0,
	CELL_PUBLIC = 1,
}

## Six entries for prestige levels 0..V. Empty disables the binding at that level.
@export var definition_keys_by_tier: PackedStringArray = PackedStringArray([
	"", "", "", "", "", "",
])
@export_enum("FamilyBranch", "CellPublic") var reward_target: int = RewardTarget.FAMILY_BRANCH

