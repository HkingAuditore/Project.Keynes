extends RefCounted

## Save previews accept the PNG, JPEG, and WebP signatures inside the same section.
## A width of 480 px keeps the thumbnail sharp in the save list.
const MAX_WIDTH := 480
const JPEG_QUALITY := 0.82


## Encodes `source` into the smallest thumbnail the UI can still use. Does not
## mutate `source`: the caller may still be holding the capture.
static func encode(source: Image) -> PackedByteArray:
	if source == null or source.is_empty():
		push_warning("[save/preview] viewport capture returned no image")
		return fallback()
	var image := Image.new()
	image.copy_from(source)
	var width := image.get_width()
	var height := image.get_height()
	if width > MAX_WIDTH and height > 0:
		var scaled_height := maxi(1, int(round(
			float(height) * float(MAX_WIDTH) / float(width))))
		image.resize(MAX_WIDTH, scaled_height, Image.INTERPOLATE_BILINEAR)
	# JPEG has no alpha channel and Godot refuses the conversion implicitly.
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)
	var jpeg := image.save_jpg_to_buffer(JPEG_QUALITY)
	if not jpeg.is_empty():
		return jpeg
	push_warning("[save/preview] JPEG encoding failed for a %s image" % image.get_size())
	return fallback()


## Returns an empty Image when the buffer is not a format this build knows.
## The format is sniffed before calling a loader: Godot's loaders log an engine
## error for every mismatch, and a save list would emit one per slot per attempt.
static func decode(bytes: PackedByteArray) -> Image:
	var image := Image.new()
	if bytes.is_empty():
		return image
	var decode_error := ERR_FILE_UNRECOGNIZED
	if _is_png(bytes):
		decode_error = image.load_png_from_buffer(bytes)
	elif _is_jpeg(bytes):
		decode_error = image.load_jpg_from_buffer(bytes)
	elif _is_webp(bytes):
		decode_error = image.load_webp_from_buffer(bytes)
	if decode_error != OK:
		push_warning("[save/preview] could not decode %d bytes: %s"
			% [bytes.size(), error_string(decode_error)])
		return Image.new()
	return image


static func _is_png(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 8 \
		and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47 \
		and bytes[4] == 0x0D and bytes[5] == 0x0A and bytes[6] == 0x1A and bytes[7] == 0x0A


static func _is_jpeg(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 3 \
		and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF


static func _is_webp(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 12 \
		and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" \
		and bytes.slice(8, 12).get_string_from_ascii() == "WEBP"


## Headless and render-to-texture-less runs still owe the slot a valid image.
static func fallback() -> PackedByteArray:
	var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color.TRANSPARENT)
	return blank.save_png_to_buffer()
