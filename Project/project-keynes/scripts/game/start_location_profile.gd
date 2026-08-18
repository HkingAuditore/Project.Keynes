class_name StartLocationProfile
extends RefCounted

const TEMPERATURE_MIN := 0.24
const TEMPERATURE_MAX := 0.82
const MOISTURE_MIN := 0.24
const MOISTURE_MAX := 0.90
const ELEVATION_MIN := 0.08
const ELEVATION_MAX := 0.82
const VITALITY_MIN := 0.18

const MINIMUM_RESERVES := {
	"fertile_soil": 350000.0,
	"timber": 300000.0,
	"wild_game": 120000.0,
	"stone": 180000.0,
	"flint": 120000.0,
	"paddy_land": 120000.0,
	"pasture": 160000.0,
	"clay": 120000.0,
	"freshwater_fish": 90000.0,
	"marine_fish": 90000.0,
	# Opening precious deposits are deliberately marginal workings, not mines.
	"gold_ore": 15000.0,
	"silver_ore": 15000.0,
}

## Opening top-up never invents fish, paddy or clay on dry inland cells.
## Pasture is included so knowledge can close without generation-time weather.
## Timber is always topped up: the opening construction backbone is deadwood.
const OPENING_TOPUP_RESOURCE_IDS := [
	"fertile_soil",
	"timber",
	"wild_game",
	"stone",
	"flint",
	"pasture",
]
