extends SceneTree

const SaveRepositoryScript := preload(
	"res://scripts/game/save_repository.gd")


func _init() -> void:
	var repository = SaveRepositoryScript.new()
	for slot in ["autosave", "autosave.pksv.bak", "manual_3.pksv.bak"]:
		var path := "user://saves/%s.pksv" % slot
		if slot.ends_with(".bak"):
			path = "user://saves/%s" % slot
		var result: Dictionary = repository._read_container(path, true)
		if not bool(result.get("ok", false)):
			print("%s -> %s" % [slot, result.get("code", "unknown")])
			continue
		var bytes_by_id: Dictionary = result.get("section_bytes", {})
		var raw: PackedByteArray = bytes_by_id.get("pkfg", PackedByteArray())
		var payload = bytes_to_var(raw) if not raw.is_empty() else null
		if not payload is Dictionary:
			print("%s pkfg missing" % slot)
			continue
		var explored: PackedByteArray = payload.get(
			"explored", PackedByteArray())
		var nonzero := 0
		for value in explored:
			nonzero += 1 if value != 0 else 0
		var context = bytes_to_var(bytes_by_id.get(
			"player_context", PackedByteArray()))
		var clock = bytes_to_var(bytes_by_id.get(
			"world_clock", PackedByteArray()))
		print("%s cells=%d explored_nonzero=%d start_cell=%s day=%s" % [
			slot, int(payload.get("cells", -1)), nonzero,
			context.get("start_cell", "?") if context is Dictionary else "?",
			clock.get("day_index", "?") if clock is Dictionary else "?"])
	quit()
