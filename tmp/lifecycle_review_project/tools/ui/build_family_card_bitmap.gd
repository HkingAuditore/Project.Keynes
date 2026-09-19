extends SceneTree

const SOURCE := "res://assets/ui/family_workspace/bitmap/card_frame_v3.png"
const OUTPUT := "res://assets/ui/family_workspace/bitmap/card_frame_clean_v4.png"
const SOURCE_REGION := Rect2i(18, 16, 1947, 761)
const OUTPUT_SIZE := Vector2i(974, 381)


func _initialize() -> void:
	var source := Image.load_from_file(SOURCE)
	if source == null or source.is_empty():
		push_error("无法读取家族卡片源图：%s" % SOURCE)
		quit(1)
		return
	var clean := source.get_region(SOURCE_REGION)
	clean.resize(OUTPUT_SIZE.x, OUTPUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var error := clean.save_png(OUTPUT)
	if error != OK:
		push_error("无法输出家族卡片位图：%s" % error_string(error))
		quit(1)
		return
	print("[family-card-bitmap] %s %s" % [OUTPUT, OUTPUT_SIZE])
	quit(0)
