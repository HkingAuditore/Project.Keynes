extends RefCounted

## Resolves vegetation distance and density limits from the selected profile.

static func _resolved_lod_thresholds(layer: ShrubLayer) -> Vector2:
	var cfg := layer._profile()
	var configured_start := float(cfg.get("lod_fade_start_zoom"))
	var configured_end := float(cfg.get("lod_fade_end_zoom"))
	if configured_start >= 0.0 and configured_end > configured_start:
		return Vector2(configured_start, configured_end)
	if ShrubLayer.ShrubScatter._spawn_domain(layer) == ShrubLayer.SPAWN_WATER:
		return Vector2(1.20, 1.70)
	match layer._detail_kind():
		ShrubLayer.DETAIL_TREE, ShrubLayer.DETAIL_CONIFER, ShrubLayer.DETAIL_PALM, ShrubLayer.DETAIL_DEAD_SNAG:
			return Vector2(0.45, 0.80)
		ShrubLayer.DETAIL_SHRUB, ShrubLayer.DETAIL_CACTUS, ShrubLayer.DETAIL_REED:
			return Vector2(0.75, 1.15)
		ShrubLayer.DETAIL_ROCK:
			return Vector2(0.90, 1.30)
		_:
			return Vector2(1.20, 1.70)


static func _resolved_lod_near_density_multiplier(layer: ShrubLayer) -> float:
	var cfg := layer._profile()
	var configured = cfg.get("lod_near_density_multiplier")
	if configured is float or configured is int:
		var configured_multiplier := float(configured)
		if configured_multiplier >= 1.0:
			return clampf(configured_multiplier, 1.0, 3.0)
	# [veg-lod-high 2026-10-18] 高画质不再按 1.75 把远景砍到 57%：拉远后整片森林只剩零散
	# 几撮，和地形/建筑的自然过渡断掉。高画质远景保留 ≈89%，中/低保持原密度以守住实例预算。
	if ShrubLayer.ShrubScatter._active_quality_tier(layer) >= 2:
		return 1.12
	if ShrubLayer.ShrubScatter._spawn_domain(layer) == ShrubLayer.SPAWN_WATER:
		return 1.30
	match layer._detail_kind():
		ShrubLayer.DETAIL_TREE, ShrubLayer.DETAIL_CONIFER, ShrubLayer.DETAIL_PALM, ShrubLayer.DETAIL_DEAD_SNAG:
			return 1.75
		ShrubLayer.DETAIL_SHRUB, ShrubLayer.DETAIL_CACTUS, ShrubLayer.DETAIL_REED:
			return 1.60
		ShrubLayer.DETAIL_ROCK:
			return 1.40
		_:
			return 1.35
