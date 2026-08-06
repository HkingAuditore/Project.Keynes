extends SceneTree

# 解码 terrain_surface_debug_view == 16 的位条截图：上半屏读宽、下半屏读高。
# 左起第 1 格 = bit11，每格 1/12 屏宽，白=1 深蓝=0，bit%4==3 的格子左缘 8% 是红分隔。
#
# 用法：godot --headless --script res://tests/_tmp_decode_texsize_view.gd -- <shot.png>


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("[decode] 需要传入截图路径")
		quit(1)
		return
	var img := Image.new()
	if img.load(args[0]) != OK:
		print("[decode] 读图失败: ", args[0])
		quit(1)
		return

	var w := img.get_width()
	var h := img.get_height()
	print("[decode] ", args[0], " size=", Vector2i(w, h))

	for half in range(2):
		# 取每格中心的一列，避开红分隔（在格子左缘 8%）；纵向取该半屏中段多行投票，
		# 躲开植被/云/UI 这些画在地表之上的图层。
		var y_lo := int((0.10 + 0.5 * float(half)) * float(h))
		var y_hi := int((0.40 + 0.5 * float(half)) * float(h))
		var bits := ""
		var val := 0
		for slot in range(12):
			var x := int((float(slot) + 0.5) / 12.0 * float(w))
			var white := 0
			var dark := 0
			for y in range(y_lo, y_hi, 3):
				var c := img.get_pixel(x, y)
				if c.r > 0.75 and c.g > 0.75 and c.b > 0.75:
					white += 1
				elif c.b > c.r and c.r < 0.35:
					dark += 1
			var one := white > dark
			bits += "1" if one else "0"
			if one:
				val |= 1 << (11 - slot)
		print("[decode]   ", "宽" if half == 0 else "高", " bits=", bits, " -> ", val)

	quit(0)
