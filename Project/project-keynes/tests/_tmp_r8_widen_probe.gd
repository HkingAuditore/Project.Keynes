extends SceneTree

# 临时探针：验证 R8 → RGBA8 的 Image.convert 语义（.r 必须保值），以及
# DCAtlasEncoders.upload_single_channel 在两种后端下产出的纹理格式。


func _init() -> void:
	print("[r8-probe] rendering_method=", RenderingServer.get_current_rendering_method(),
		" compat=", DCFeatureFlags.is_compatibility_renderer())

	var W := 8
	var H := 4
	var data := PackedByteArray()
	data.resize(W * H)
	for i in range(W * H):
		data[i] = (i * 7) % 256

	var src := Image.create_from_data(W, H, false, Image.FORMAT_R8, data)
	var dst := Image.create_from_data(W, H, false, Image.FORMAT_R8, data)
	dst.convert(Image.FORMAT_RGBA8)
	print("[r8-probe] convert R8->RGBA8 ok? fmt=", dst.get_format(),
		" (expect ", Image.FORMAT_RGBA8, ")")

	var max_err := 0.0
	var sample := []
	for y in range(H):
		for x in range(W):
			var a := src.get_pixel(x, y).r
			var b := dst.get_pixel(x, y).r
			max_err = max(max_err, abs(a - b))
			if sample.size() < 4:
				sample.append("(%d,%d) r8=%.4f rgba8=%.4f g=%.3f b=%.3f a=%.3f" % [
					x, y, a, b,
					dst.get_pixel(x, y).g, dst.get_pixel(x, y).b, dst.get_pixel(x, y).a])
	for s in sample:
		print("[r8-probe]   ", s)
	print("[r8-probe] max |r| error = ", max_err, "  -> ", "PASS" if max_err < 1e-6 else "FAIL")

	var tex := DCAtlasEncoders.upload_single_channel(data, W, H)
	print("[r8-probe] upload_single_channel: size=", tex.get_size(),
		" fmt=", tex.get_format())
	var round_trip := tex.get_image()
	var rt_err := 0.0
	for y in range(H):
		for x in range(W):
			rt_err = max(rt_err, abs(src.get_pixel(x, y).r - round_trip.get_pixel(x, y).r))
	print("[r8-probe] texture round-trip max |r| error = ", rt_err,
		" -> ", "PASS" if rt_err < 1e-6 else "FAIL")

	# 复用路径：existing 尺寸/格式一致时应原地 update 并返回同一对象
	var tex2 := DCAtlasEncoders.upload_single_channel(data, W, H, tex)
	print("[r8-probe] reuse existing -> same object? ", tex2 == tex,
		" fmt=", tex2.get_format())

	quit(0)
