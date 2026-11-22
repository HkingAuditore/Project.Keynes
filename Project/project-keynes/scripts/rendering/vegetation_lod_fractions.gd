extends RefCounted

static func _family_far_fraction(family: int) -> float:
	match family:
		3:
			return 0.08
		2, 4:
			return 0.0
		1, 5:
			return 0.0
	return 0.0


static func _family_lod_fraction_base(family: int, zoom_value: float) -> float:
	# 每个切换点用 0.10 zoom 交叉带；稳定前缀保证密度变化时不会整格消失。
	match family:
		3: # Canopy: 8% overview -> 40% mid -> 100% near.
			if zoom_value < 0.45:
				return 0.08
			if zoom_value < 0.55:
				return lerpf(0.08, 0.40, smoothstep(0.45, 0.55, zoom_value))
			if zoom_value < 0.85:
				return 0.40
			if zoom_value < 0.95:
				return lerpf(0.40, 1.0, smoothstep(0.85, 0.95, zoom_value))
			return 1.0
		2, 4: # Brush / Hardscape.
			if zoom_value < 0.65:
				return 0.0
			if zoom_value < 0.75:
				return 0.35 * smoothstep(0.65, 0.75, zoom_value)
			if zoom_value < 1.15:
				return 0.35
			if zoom_value < 1.25:
				return lerpf(0.35, 1.0, smoothstep(1.15, 1.25, zoom_value))
			return 1.0
		1, 5: # Ground / Aquatic.
			if zoom_value < 1.00:
				return 0.0
			if zoom_value < 1.10:
				return 0.25 * smoothstep(1.00, 1.10, zoom_value)
			if zoom_value < 1.55:
				return 0.25
			if zoom_value < 1.65:
				return lerpf(0.25, 1.0, smoothstep(1.55, 1.65, zoom_value))
			return 1.0
	return 1.0
