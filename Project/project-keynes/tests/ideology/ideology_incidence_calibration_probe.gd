extends SceneTree

## Calibration + reachability probe for the material support model.
##
## No world, no clock: it compiles the production catalogs, builds a handful of
## synthetic class-share archetypes, and runs the SAME formula the native kernel
## runs. Output is the data the κ and threshold decision needs:
##   * how many cards clear adopt / repeal / promote per archetype,
##   * which cards have an all-zero channel row (structurally un-gateable),
##   * which cards can never pass in any archetype (dead ends).
##
## The archetype shares are approximations on purpose (population-weighted class
## influence, uniform need baskets). They are a calibration target, not evidence
## about a specific save.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ProfileScript = preload("res://scripts/ideology/ideology_profile.gd")

const Q16 := 65536
const SECTOR_COUNT := 6
const PREFIX := 11

## class order: general, farmer, worker, technology, military
const CLASSES := ["general", "farmer", "worker", "technology", "military"]

## Archetype: population share per class, sector income weight per sector, and
## whether the country owns many buildings (owner profit share).
const ARCHETYPES := {
	"all_general": {"pop": [1000, 0, 0, 0, 0], "sectors": [1, 1, 1, 1, 1, 0], "owners": 0},
	"agrarian": {"pop": [80, 720, 120, 40, 40], "sectors": [7, 1, 1, 0, 0, 0], "owners": 1},
	"industrial": {"pop": [150, 120, 600, 80, 50], "sectors": [2, 2, 5, 2, 1, 0], "owners": 1},
	"knowledge": {"pop": [120, 60, 300, 470, 50], "sectors": [1, 1, 3, 2, 4, 0], "owners": 1},
	"military": {"pop": [300, 300, 300, 30, 470], "sectors": [2, 2, 3, 1, 1, 2], "owners": 1},
}


func _init() -> void:
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		print("ECONOMY_FAIL ", economy.get("reason", ""))
		quit(1)
		return
	var catalog: Dictionary = IdeologyCatalogScript.load_default().compile_native_catalog(
		economy, economy)
	if not bool(catalog.get("ok", false)):
		print("CATALOG_FAIL ", catalog.get("reason", ""))
		quit(1)
		return
	var profile := ProfileScript.new()
	var channels := int(catalog.get("incidence_channel_count", 0))
	var rows: PackedInt32Array = catalog.get("incidence_level_channels_q16",
		PackedInt32Array())
	var levels: PackedInt32Array = catalog.get("level_offsets", PackedInt32Array())
	var level_count := int(levels[levels.size() - 1]) if levels.size() > 0 else 0
	var ids: PackedStringArray = catalog.get("ideology_ids", PackedStringArray())
	var thresholds: PackedInt32Array = catalog.get("adopt_thresholds_q16",
		PackedInt32Array())
	var repeal_thresholds: PackedInt32Array = catalog.get("repeal_thresholds_q16",
		PackedInt32Array())
	var promote_thresholds: PackedInt32Array = catalog.get("promote_thresholds_q16",
		PackedInt32Array())
	print("cards=%d levels=%d channels=%d gain=%d" % [
		ids.size(), level_count, channels, int(profile.incidence_gain_q16)])
	if channels <= 0 or ids.size() == 0:
		print("NO_TABLE")
		quit(1)
		return

	var need_count := channels - PREFIX
	var need_share := Q16 / maxi(1, need_count)
	# Scale sweep: κ is fixed at the profile default, and the authored thresholds
	# are multiplied by a candidate scale. This is the knob `incidence_threshold_scale_q16`
	# exposes; the table below is how its value gets chosen.
	var gain: int = int(profile.incidence_gain_q16)
	for scale in [65536, 49152, 32768, 22938, 16384]:
		var line := PackedStringArray()
		for archetype in ARCHETYPES.keys():
			var spec: Dictionary = ARCHETYPES[archetype]
			var shares := _share_rows(spec, channels, need_count, need_share)
			var influence := _influence(spec["pop"])
			var adopt_pass := 0
			var promote_pass := 0
			for card in ids.size():
				var delta := _delta_row(rows, int(levels[card]), channels)
				if _is_zero(delta):
					continue
				var stances := _stances(shares, delta, channels, gain)
				var support := _weighted(influence, stances)
				if support >= int(thresholds[card]) * scale / Q16:
					adopt_pass += 1
					if support >= int(promote_thresholds[card]) * scale / Q16:
						promote_pass += 1
			line.append("%s=%d/%d(promote %d)" % [archetype, adopt_pass, ids.size(),
				promote_pass])
		print("scale=%.2f  %s" % [float(scale) / Q16, " ".join(line)])

	var dead_cards := PackedStringArray()
	var never_adopt := PackedStringArray()
	var per_archetype: Dictionary = {}
	for archetype in ARCHETYPES.keys():
		var spec: Dictionary = ARCHETYPES[archetype]
		var shares := _share_rows(spec, channels, need_count, need_share)
		var influence := _influence(spec["pop"])
		var adopt_pass := 0
		var repeal_pass := 0
		var promote_pass := 0
		for card in ids.size():
			var level_index := int(levels[card])  # first level of this card
			var delta := _delta_row(rows, level_index, channels)
			if _is_zero(delta):
				if not dead_cards.has(ids[card]):
					dead_cards.append(ids[card])
				continue
			var stances := _stances(shares, delta, channels,
				int(profile.incidence_gain_q16))
			var support := _weighted(influence, stances)
			if support >= int(thresholds[card]):
				adopt_pass += 1
			if -support >= int(repeal_thresholds[card]):
				repeal_pass += 1
			if support >= int(promote_thresholds[card]):
				promote_pass += 1
			elif not per_archetype.has("promote_never"):
				per_archetype["promote_never"] = []
		per_archetype[archetype] = {"adopt": adopt_pass, "repeal": repeal_pass,
			"promote": promote_pass}
		print("%-12s adopt=%3d/%d repeal=%3d promote=%3d" % [archetype,
			adopt_pass, ids.size(), repeal_pass, promote_pass])

	# A card nobody can adopt in ANY archetype is a structural dead end.
	for card in ids.size():
		var level_index := int(levels[card])
		var delta := _delta_row(rows, level_index, channels)
		if _is_zero(delta):
			continue
		var adopt_anywhere := false
		for archetype in ARCHETYPES.keys():
			var spec: Dictionary = ARCHETYPES[archetype]
			var shares := _share_rows(spec, channels, need_count, need_share)
			var stances := _stances(shares, delta, channels,
				int(profile.incidence_gain_q16))
			if _weighted(_influence(spec["pop"]), stances) >= int(thresholds[card]):
				adopt_anywhere = true
				break
		if not adopt_anywhere:
			never_adopt.append(ids[card])
	print("dead_cards(all-zero row)=%d" % dead_cards.size())
	if not dead_cards.is_empty():
		print("  ", ", ".join(dead_cards.slice(0, 10)))
	print("never_adopt(any archetype)=%d" % never_adopt.size())
	if not never_adopt.is_empty():
		print("  ", ", ".join(never_adopt.slice(0, 10)))
	quit(0)


func _share_rows(spec: Dictionary, channels: int, need_count: int,
		need_share: int) -> Array:
	var sectors: Array = spec["sectors"]
	var total := 0
	for sector in 5:
		total += int(sectors[sector])
	var rows: Array = []
	for class_index in CLASSES.size():
		var row := PackedInt32Array()
		row.resize(channels)
		row.fill(0)
		for sector in SECTOR_COUNT:
			if sector >= 5:
				continue
			row[sector] = int(sectors[sector]) * Q16 / maxi(1, total)
		row[6] = Q16 / 6
		row[7] = 0 if int(spec["owners"]) == 0 else Q16 / 4
		row[8] = 0
		row[9] = Q16
		row[10] = Q16
		for need in need_count:
			row[PREFIX + need] = need_share
		rows.append(row)
	return rows


func _influence(pop: Array) -> Array:
	var total := 0
	for value in pop:
		total += int(value)
	var out: Array = []
	for value in pop:
		out.append(0 if total <= 0 else int(value) * Q16 / total)
	return out


func _delta_row(rows: PackedInt32Array, level_index: int, channels: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(channels)
	var base := level_index * channels
	for channel in channels:
		var index := base + channel
		out[channel] = int(rows[index]) if index < rows.size() else 0
	return out


func _is_zero(delta: PackedInt32Array) -> bool:
	for value in delta:
		if value != 0:
			return false
	return true


func _stances(shares: Array, delta: PackedInt32Array, channels: int,
		gain: int) -> Array:
	var out: Array = []
	for row in shares:
		var acc := 0
		for channel in channels:
			acc += int(row[channel]) * int(delta[channel])
		var delta_u := acc / Q16
		var stance := clampi(delta_u * gain / Q16, -Q16, Q16)
		out.append(stance)
	return out


func _weighted(influence: Array, stances: Array) -> int:
	var total := 0
	var weighted := 0
	for i in influence.size():
		total += int(influence[i])
		weighted += int(influence[i]) * int(stances[i])
	return 0 if total <= 0 else weighted / total
