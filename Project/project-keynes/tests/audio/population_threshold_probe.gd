extends RefCounted

## Finds the live audio tier boundaries by calling the service itself. Tests do
## not mirror population tuning values from game_audio_service.gd.

static func tier(audio: Object) -> int:
	return int(audio.diagnostics().get("pop_tier", -1))

static func find_entry(audio: Object, method: StringName, target_tier: int) -> int:
	var call := Callable(audio, method)
	call.call(0)
	var low := 0
	var high := 1
	while tier(audio) < target_tier:
		low = high
		call.call(high)
		high *= 2
	if tier(audio) < target_tier:
		return -1
	while low + 1 < high:
		var middle := (low + high) / 2
		call.call(middle)
		if tier(audio) >= target_tier:
			high = middle
		else:
			low = middle
	return high

static func find_exit(audio: Object, method: StringName, entry: int, target_tier: int) -> int:
	if entry <= 0:
		return -1
	var call := Callable(audio, method)
	call.call(entry)
	var high := entry
	var low := 0
	while high > 1:
		var middle := high / 2
		call.call(middle)
		if tier(audio) < target_tier:
			low = middle
			break
		high = middle
	if low == 0 and tier(audio) >= target_tier:
		call.call(0)
		if tier(audio) >= target_tier:
			return -1
		low = 0
	while low + 1 < high:
		var middle := (low + high) / 2
		call.call(middle)
		if tier(audio) < target_tier:
			low = middle
		else:
			high = middle
	return low
