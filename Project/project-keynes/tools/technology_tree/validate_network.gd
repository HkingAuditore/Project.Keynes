extends SceneTree

## 轻量校验入口：只跑 TechnologyNetworkValidator，不加载经济/存档。
## 用法：
##   godot --headless --path <project> --script res://tools/technology_tree/validate_network.gd
##   godot --headless --path <project> --script res://tools/technology_tree/validate_network.gd -- --limit=80

const NETWORK_PATH := "res://data/technology/technology_network.json"
const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")


func _init() -> void:
	var limit := 60
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--limit="):
			limit = int(argument.substr(8))
	var path := ProjectSettings.globalize_path(NETWORK_PATH)
	if not FileAccess.file_exists(NETWORK_PATH):
		printerr("missing network: %s" % NETWORK_PATH)
		quit(2)
		return
	var text := FileAccess.get_file_as_string(NETWORK_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("network is not a JSON object")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var result: Dictionary = ValidatorScript.validate(parsed)
	var findings: Array = result.get("findings", [])
	var errors: Array = []
	var warnings: Array = []
	for value in findings:
		var finding: Dictionary = value
		if String(finding.get("severity", "")) == ValidatorScript.SEVERITY_ERROR:
			errors.append(finding)
		else:
			warnings.append(finding)
	print("NETWORK %s" % path)
	print("VALIDATE ok=%s errors=%d warnings=%d in %d ms" % [
		str(result.get("ok", false)), errors.size(), warnings.size(),
		Time.get_ticks_msec() - started])
	var stats: Dictionary = result.get("stats", {})
	var keys := stats.keys()
	keys.sort()
	for key in keys:
		print("  stat %s = %s" % [key, str(stats[key])])
	var shown := 0
	for value in errors:
		if shown >= limit:
			print("  ... (%d errors truncated)" % (errors.size() - shown))
			break
		print("  ERROR %s | %s" % [
			String(value.get("code", "")), String(value.get("message", ""))])
		shown += 1
	shown = 0
	for value in warnings:
		if shown >= limit:
			print("  ... (%d warnings truncated)" % (warnings.size() - shown))
			break
		print("  WARN  %s | %s" % [
			String(value.get("code", "")), String(value.get("message", ""))])
		shown += 1
	quit(0 if errors.is_empty() else 1)
