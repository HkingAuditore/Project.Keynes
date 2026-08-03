class_name FamilyBehaviorPreference
extends Resource

enum Axis {
	INVESTMENT_BUILDING = 0,
	CAREER_PROFESSION = 1,
	CONSUMPTION_NEED = 2,
}

enum SelectorKind {
	STABLE_ID = 0,
	BUILDING_SECTOR = 1,
}

@export_enum("InvestmentBuilding", "CareerProfession", "ConsumptionNeed") \
var axis: int = Axis.INVESTMENT_BUILDING
@export_enum("StableId", "BuildingSector") var selector_kind: int = SelectorKind.STABLE_ID
@export var selector_id: StringName = &""
## Q16 multiplier at full trait strength. Runtime interpolates from neutral.
@export_range(0, 262144, 1) var factor_q16: int = 65536

