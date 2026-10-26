class_name IdeologyLevelProgress
extends RefCounted

## Pure calculation boundary between the native snapshot and the level widgets.
## Keeping threshold lookup here means the cabinet and collection cannot drift
## when a catalog row is missing levels (common in UI fixtures).

const DEFAULT_LEVEL_COUNT := 3


static func build(metadata: Dictionary, state: Dictionary,
		level_label_override := "") -> Dictionary:
	var thresholds: PackedInt64Array = metadata.get(
		"level_thresholds_q16", PackedInt64Array())
	var level := clampi(int(state.get("level", 0)), 0, 64)
	var level_count := maxi(1, thresholds.size())
	if level_count <= 1:
		var labels: PackedStringArray = metadata.get(
			"level_labels", PackedStringArray())
		var effect_sets: Array = metadata.get("level_effect_lines", [])
		level_count = maxi(1, maxi(labels.size(), effect_sets.size()))
		if level_count <= 1:
			level_count = DEFAULT_LEVEL_COUNT
	var labels: PackedStringArray = metadata.get(
		"level_labels", PackedStringArray())
	var level_label := level_label_override.strip_edges()
	if level_label.is_empty() and level >= 0 and level < labels.size():
		level_label = String(labels[level])
	var amount := maxi(0, int(state.get("understanding", 0)))
	var maxed := level + 1 >= level_count
	var low := _threshold(thresholds, level, 0)
	var high := _threshold(thresholds, level + 1, low)
	var progress := 1.0 if maxed else 0.0
	if not maxed:
		progress = clampf(float(amount - low) / float(maxi(1, high - low)),
			0.0, 1.0)
	return {
		"level": level,
		"level_count": level_count,
		"level_label": level_label,
		"understanding_q16": amount,
		"low_q16": low,
		"threshold_q16": high,
		"progress": progress,
		"maxed": maxed,
	}


static func _threshold(values: PackedInt64Array, index: int,
		fallback: int) -> int:
	if index >= 0 and index < values.size():
		return maxi(0, int(values[index]))
	return fallback
