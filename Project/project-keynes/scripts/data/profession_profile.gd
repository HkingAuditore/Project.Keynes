class_name ProfessionProfile
extends Resource

## Stable identity fields. Display data may change without invalidating saves.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export var default_consumption_plan_id: StringName = &""
## UI/content taxonomy only; employment identity remains the stable profession id.
@export var profession_class_id: StringName = &"general"
## Savings gate for upward mobility, standing in for the education and literacy
## the simulation does not model: a cohort may move people into this profession
## only while its per-capita funds cover this many days of the cell's
## per-capita living cost. Moves from a profession with an equal or higher gate
## are exempt, so lateral and downward mobility stay free.
@export_range(0, 36500, 1) var entry_savings_days: int = 0
## Optional cold-path labels for family/job selectors.
@export var semantic_tags: PackedStringArray = PackedStringArray()
## Executable availability requirements. Only `tech.*` tags are interpreted by
## the economy runtime; other namespaces remain descriptive metadata.
@export var technology_tags: PackedStringArray = PackedStringArray()

## Per-person, per-day Q32 demographic rates.
## 20.0% births and 7.5% pre-technology natural deaths per 365-day year. The
## country stat `country.population.death_factor` (storage, sanitation and
## medicine technologies, floor 1/3) lowers natural deaths toward 2.5%, and
## composite satisfaction above the birth reference raises births up to 1.15x,
## so a developed, well-fed population grows near 20% per year while a stagnant
## stone-age one grows near 12.5%. A well-fed 40-person starter settlement
## averages one birth about every 30 days while small-country support is full.
## Composite satisfaction fully modulates births. Healthy cohorts retain the
## gameplay-scale rate while severe deprivation sharply suppresses births.
@export var birth_rate_q32: int = 2353407
@export var death_rate_q32: int = 882528
@export var satisfaction_birth_weight_q16: int = 65536

## Q16 weights for the eight composite satisfaction dimensions, in native enum
## order: subsistence, basic, comfort, luxury, income growth, savings, tax
## burden, social development. This is where class (阶层) differentiation lives:
## a subsistence farmer weights survival and savings, a merchant weights income
## growth and tax burden, a notable weights luxury and development.
## Leave empty to inherit `EconomyProfile.satisfaction_default_dimension_weights_q16`.
## A dimension whose weight is 0 never enters the composite denominator.
@export var satisfaction_dimension_weights_q16: PackedInt32Array = PackedInt32Array()
