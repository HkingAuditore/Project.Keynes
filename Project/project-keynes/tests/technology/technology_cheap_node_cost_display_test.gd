extends SceneTree

# The runtime floors every technology at one scaled unit
# (country_effective_research_cost: `if (base_cost < 1) base_cost = 1`), so a
# node authored with cost_points 0 — tech.hide_scraping, and every
# starter-eligible node, which compiles to 0 — still has to be paid for.
#
# public_definitions()["cost_points"] is an integer point count
# (technology_costs / 1000) and collapses to 0 for anything cheaper than one
# point. The technology card divided by that value, so such a node rendered as
# 「研究队列中 · 0% · 还需 0」 while the runtime was still waiting on payment.
# cost_points_scaled carries the runtime's own units with the same floor.

const TechnologyCatalogScript = preload(
	"res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const POINT_SCALE := 1000.0

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology cheap node cost display: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var costs: PackedInt64Array = compiled.get("technology_costs",
		PackedInt64Array())
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	_expect("public definitions align with compiled costs",
		definitions.size() == costs.size() and not definitions.is_empty())
	if definitions.size() != costs.size():
		return

	var cheap_indices: Array[int] = []
	for index in range(costs.size()):
		if int(costs[index]) < int(POINT_SCALE):
			cheap_indices.append(index)
	_expect("catalog contains sub-point technologies", not cheap_indices.is_empty())

	var missing_scaled := 0
	var zero_scaled := 0
	var caption_reads_zero := 0
	for index in cheap_indices:
		var definition: Dictionary = definitions[index]
		if not definition.has("cost_points_scaled"):
			missing_scaled += 1
			continue
		var scaled := int(definition.get("cost_points_scaled", 0))
		if scaled < 1:
			zero_scaled += 1
		# What the detail card reports for an untouched node (fraction 0).
		if _remaining_points(definition, 0.0) <= 0.0:
			caption_reads_zero += 1
	_expect("every sub-point technology exposes cost_points_scaled",
		missing_scaled == 0)
	_expect("scaled cost honours the runtime floor of one unit", zero_scaled == 0)
	_expect("an unpaid sub-point technology never reports 还需 0",
		caption_reads_zero == 0)

	# tech.hide_scraping is the node this regression was reported against.
	var ids: PackedStringArray = compiled.technology_ids
	var hide_scraping := ids.find("tech.hide_scraping")
	_expect("tech.hide_scraping exists", hide_scraping >= 0)
	if hide_scraping >= 0:
		var definition: Dictionary = definitions[hide_scraping]
		_expect("tech.hide_scraping is authored as a zero-point node",
			int(definition.get("cost_points", -1)) == 0)
		_expect("tech.hide_scraping still reports outstanding research",
			_remaining_points(definition, 0.0) > 0.0)


# Mirrors TechnologyDetailCard._progress_caption's remaining computation.
func _remaining_points(definition: Dictionary, fraction: float) -> float:
	var cost_scaled := maxf(1.0, float(definition.get("cost_points_scaled",
		float(definition.get("cost_points", 0)) * POINT_SCALE)))
	return maxf(0.0, cost_scaled * (1.0 - clampf(fraction, 0.0, 1.0))) \
		/ POINT_SCALE
