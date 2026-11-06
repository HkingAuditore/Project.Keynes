class_name EconomyTestBootstrap
extends RefCounted

const Inputs = preload("res://scripts/economy/bootstrap/test_start_inputs.gd")
const Planner = preload("res://scripts/economy/bootstrap/test_settlement_planner.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
const DEFAULT_POPULATION_SCALE = Policy.DEFAULT_POPULATION_SCALE
const SUPPORTED_POPULATION_SCALES = Policy.SUPPORTED_POPULATION_SCALES

# Composition only: freeze the external inputs, then plan without runtime access.
static func build(map: MapData, facade: EconomyFacade, _seed: int,
		population_scale: int = 1) -> Dictionary:
	var captured := Inputs.capture(map, facade)
	if not bool(captured.get("ok", false)):
		return captured
	return Planner.build(captured.inputs, population_scale)
