class_name EraRewardTargetSelector
extends Resource

enum EntityType {
	COUNTRY = 0,
	CELL = 1,
	SETTLEMENT = 2,
	BUILDING = 3,
	COHORT = 4,
	FAMILY = 5,
	PERSON = 6,
}

enum Ranking {
	STABLE_HANDLE_ASC = 0,
	POPULATION_DESC = 1,
	OUTPUT_DESC = 2,
	SHORTAGE_DESC = 3,
	PRESTIGE_DESC = 4,
}

@export var entity_type: EntityType = EntityType.COUNTRY
@export var filter_code: int = 0
@export var ranking: Ranking = Ranking.STABLE_HANDLE_ASC
@export_range(1, 32, 1) var top_n: int = 1
@export_range(1, 32, 1) var minimum_targets: int = 1
