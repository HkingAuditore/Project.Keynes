extends RefCounted


## Replaces NaN/INF floats with null so JSON.stringify cannot silently write null
## for an unknown metric, and records the offending paths for the log line.
static func sanitize_non_finite(value, path: String, reported: Array):
	if value is float:
		var number := float(value)
		if is_nan(number) or is_inf(number):
			if reported.size() < 32:
				reported.append(path)
			return null
		return number
	if value is PackedFloat32Array or value is PackedFloat64Array:
		var floats := []
		for index in range(value.size()):
			floats.append(sanitize_non_finite(float(value[index]),
				"%s[%d]" % [path, index], reported))
		return floats
	if value is Dictionary:
		var sanitized := {}
		for key in value:
			sanitized[key] = sanitize_non_finite(value[key],
				"%s.%s" % [path, key], reported)
		return sanitized
	if value is Array:
		var sanitized_array := []
		for index in range(value.size()):
			sanitized_array.append(sanitize_non_finite(value[index],
				"%s[%d]" % [path, index], reported))
		return sanitized_array
	return value
