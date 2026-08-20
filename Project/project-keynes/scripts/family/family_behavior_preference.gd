class_name FamilyBehaviorPreference
extends Resource

enum Axis {
	INVESTMENT_BUILDING = 0,
	CAREER_PROFESSION = 1,
	CONSUMPTION_NEED = 2,
	CONSUMPTION_GOOD = 3,
}

enum SelectorKind {
	STABLE_ID = 0,
	BUILDING_SECTOR = 1,
	CATEGORY = 2,
	SUBSTITUTION_CATEGORY = 3,
	SEMANTIC_TAG = 4,
}

## Packed scoring term consumed by investment/employment after FAMILY_COMMIT freeze.
## CANDIDATE_WEIGHT keeps the existing selector multiplier. Other terms are
## family/cell scalars mixed with already-available candidate fields.
enum ScoreTerm {
	CANDIDATE_WEIGHT = 0,
	TAX_SENSITIVITY = 1,
	LOCAL_RESOURCE_ABUNDANCE = 2,
	UPGRADE_TIER = 3,
	LOCAL_POPULARITY = 4,
	CAREER_MOBILITY = 5,
}

@export_enum("InvestmentBuilding", "CareerProfession", "ConsumptionNeed", "ConsumptionGood") \
var axis: int = Axis.INVESTMENT_BUILDING
@export_enum("StableId", "BuildingSector", "Category", "SubstitutionCategory", \
	"SemanticTag") var selector_kind: int = SelectorKind.STABLE_ID
@export var selector_id: StringName = &""
## Q16 multiplier at full trait strength. Runtime interpolates from neutral.
@export_range(0, 262144, 1) var factor_q16: int = 65536
@export_enum("CandidateWeight", "TaxSensitivity", "LocalResourceAbundance", \
	"UpgradeTier", "LocalPopularity", "CareerMobility") \
var score_term: int = ScoreTerm.CANDIDATE_WEIGHT
## Packed EffectCondition IR. Evaluated only at FAMILY_COMMIT / metric revision.
@export var conditions: Array[Resource] = []
