extends SceneTree

## Save-slot thumbnail contract: new saves store a scaled JPEG, and a reader must
## still accept the full-window PNG that older saves carry. See
## scripts/game/save_preview_codec.gd and the preview section owned by
## scripts/game/save_modules/player_state.gd.

const Codec = preload("res://scripts/game/save_preview_codec.gd")
const PlayerState = preload("res://scripts/game/save_modules/player_state.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var image := Image.create(800, 600, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.18, 0.32, 0.46))
	# Deterministic blocks stand in for map terrain; a flat image would not
	# exercise JPEG quantisation at all.
	for index in 24:
		var rect := Rect2i((index * 97) % 760, (index * 53) % 560, 40, 30)
		image.fill_rect(rect, Color(0.78, 0.58 - 0.015 * float(index), 0.28))

	var jpeg := Codec.encode(image)
	_expect("encode returns a buffer", jpeg.size() > 0)
	_expect("encodes JPEG, not PNG",
		jpeg.size() > 2 and jpeg[0] == 0xFF and jpeg[1] == 0xD8)
	# The old full-window PNG was 0.86 MB of a 9.96 MB save. A 480-wide
	# thumbnail of this kind of content stays well under 120 KB.
	_expect("thumbnail is small (got %d bytes)" % jpeg.size(), jpeg.size() < 120 * 1024)

	var decoded := Codec.decode(jpeg)
	_expect("decode returns an image", not decoded.is_empty())
	_expect("width is capped at MAX_WIDTH", decoded.get_width() == Codec.MAX_WIDTH)
	# 800x600 -> 480x360.
	_expect("aspect ratio is kept", absi(decoded.get_height() - 360) <= 1)

	# A slot written before this change carries a full-window PNG.
	var legacy_png := image.save_png_to_buffer()
	var legacy := Codec.decode(legacy_png)
	_expect("legacy PNG preview still decodes",
		not legacy.is_empty() and legacy.get_width() == 800)
	var webp := Codec.decode(image.save_webp_to_buffer())
	_expect("legacy WebP preview still decodes",
		not webp.is_empty() and webp.get_size() == image.get_size())

	# A 1x1 fallback (headless save) must decode too, and junk must not.
	var fallback := Codec.decode(Codec.fallback())
	_expect("fallback decodes", not fallback.is_empty())
	if DisplayServer.get_name() == "headless":
		var headless_preview := Codec.decode(PlayerState.new()._capture_preview({"viewport": null}))
		_expect("headless save intentionally uses the placeholder", headless_preview.get_size() == Vector2i.ONE)
	var failed_capture := Codec.decode(Codec.encode(Image.new()))
	_expect("failed capture preserves a valid one-pixel placeholder",
		failed_capture.get_size() == Vector2i.ONE and failed_capture.get_pixel(0, 0).a == 0.0)
	_expect("empty optional preview decodes to an empty image", Codec.decode(PackedByteArray()).is_empty())
	_expect("unknown bytes decode to an empty image",
		Codec.decode(PackedByteArray([1, 2, 3, 4])).is_empty())

	# Smaller captures are not upscaled.
	var small := Image.create(320, 200, false, Image.FORMAT_RGBA8)
	small.fill(Color(0.4, 0.4, 0.4))
	var small_jpeg := Codec.encode(small)
	var small_decoded := Codec.decode(small_jpeg)
	_expect("small captures keep their size",
		small_decoded.get_width() == 320 and small_decoded.get_height() == 200)

	print("save preview codec: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
