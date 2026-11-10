extends RefCounted

## Pure priority-based platform profile selection; preserves manifest drawing order.

static func _select_platform_limited_detail_profiles(_keep_ratio: float, layers: Array) -> Array:
	var total := layers.size()
	if total <= 1:
		return layers
	var keep := maxi(1, int(round(float(total) * _keep_ratio)))
	if keep >= total:
		return layers
	var ranked: Array = []
	for i in range(total):
		ranked.append({
			"index": i,
			"priority": _detail_profile_keep_priority(layers[i]),
		})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := int(a.get("priority", 0))
		var pb := int(b.get("priority", 0))
		if pa != pb:
			return pa > pb
		return int(a.get("index", 0)) < int(b.get("index", 0))
	)
	var keep_indices: Array = []
	for i in range(keep):
		keep_indices.append(int(ranked[i].get("index", 0)))
	keep_indices.sort()
	var out: Array = []
	for raw_index in keep_indices:
		out.append(layers[int(raw_index)])
	return out


static func _detail_profile_keep_priority(prof: Resource) -> int:
	if prof == null:
		return 0
	var form := -1
	if prof.has_method("resolved_visual_form"):
		form = int(prof.call("resolved_visual_form"))
	# "额外配色"的乔木变体：与通用阔叶层同形，降档到点缀级。
	if form == ShrubVisualProfile.FORM_BROADLEAF \
			and bool(prof.get("base_color_override_enabled")):
		return 40
	match form:
		ShrubVisualProfile.FORM_BROADLEAF:
			return 100
		ShrubVisualProfile.FORM_SHRUB:
			return 98
		ShrubVisualProfile.FORM_GRASS:
			return 96
		ShrubVisualProfile.FORM_CONIFER:
			return 92
		ShrubVisualProfile.FORM_PALM:
			return 88
		ShrubVisualProfile.FORM_CACTUS:
			return 84
		ShrubVisualProfile.FORM_REED:
			return 80
		ShrubVisualProfile.FORM_ROCK:
			return 70
		ShrubVisualProfile.FORM_SCREE:
			return 66
		ShrubVisualProfile.FORM_FLOWER:
			return 62
		ShrubVisualProfile.FORM_LICHEN:
			return 60
		ShrubVisualProfile.FORM_PEAT_TUFT:
			return 58
		ShrubVisualProfile.FORM_MANGROVE:
			return 56
		ShrubVisualProfile.FORM_FALLEN_LOG:
			return 54
		ShrubVisualProfile.FORM_SNAG:
			return 52
		ShrubVisualProfile.FORM_SNOW_MOUND:
			return 44
		ShrubVisualProfile.FORM_KELP:
			return 20
		ShrubVisualProfile.FORM_CORAL:
			return 18
	return 1
