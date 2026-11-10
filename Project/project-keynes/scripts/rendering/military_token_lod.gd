extends RefCounted

## Pure token LOD transitions and names. Keeps the existing hysteresis thresholds.

const LOD_AGGREGATE := 0

const LOD_REPRESENTATIVE := 1

const LOD_FORMATION := 2

const AGGREGATE_EXIT_ZOOM := 0.37

const AGGREGATE_REENTER_ZOOM := 0.33

const FORMATION_ENTER_EXIT_ZOOM := 0.72

const FORMATION_EXIT_ZOOM := 0.68

static func lod_for_zoom_with_hysteresis(zoom: float, current: int) -> int:
	match current:
		LOD_AGGREGATE:
			return LOD_REPRESENTATIVE if zoom > AGGREGATE_EXIT_ZOOM else LOD_AGGREGATE
		LOD_REPRESENTATIVE:
			if zoom < AGGREGATE_REENTER_ZOOM:
				return LOD_AGGREGATE
			if zoom > FORMATION_ENTER_EXIT_ZOOM:
				return LOD_FORMATION
			return LOD_REPRESENTATIVE
		LOD_FORMATION:
			return LOD_REPRESENTATIVE if zoom < FORMATION_EXIT_ZOOM else LOD_FORMATION
	return LOD_REPRESENTATIVE


static func _lod_name(mode: int) -> String:
	match mode:
		LOD_AGGREGATE:
			return "aggregate"
		LOD_FORMATION:
			return "formation"
	return "representative"
