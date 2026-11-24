extends SceneTree

## [fog-premultiply 2026-11-21 / _commit_a 29eb0b3c3 + 01c051e76]
## 迷雾非 100% 档的 blit 必须是预乘 alpha。
##
## 背景：迷雾在 `_effective_render_scale() < 100` 时把雾画进一个
## `transparent_bg = true` 的 SubViewport，shader 把直通 alpha 的 `vec4(col, alpha)`
## 写进 COLOR。混合进全透明目标后，纹理里存的已经是预乘色 `rgb * alpha`。
## 再用默认 blend_mix 上屏，RGB 会再乘一次 alpha ⇒ 半透明雾整体偏暗（薄雾最明显，
## 50% 档实测亮度比 ~0.75）。
##
## 落点变更：用户版这处 blit 原本在 `fog_of_war_layer._build_scaled_target()`；
## 当前底座把它抽成了 `scripts/rendering/fog_render_target.gd` 的 `build()`，
## FogOfWarLayer 通过 `_scaled`（`_sub_viewport` / `_blit_sprite` 是转发 getter）
## 暴露同一组节点。本用例按新落点断言，语义与源提交完全一致。
##
## 分两层验：
##   1) 结构层（headless 可跑）：三档的节点关系 + 材质 blend_mode 到底有没有设上；
##   2) 像素层（需要真实渲染设备）：用**同一套构造**（transparent SubViewport →
##      Sprite2D → CanvasItemMaterial）做 50% 红叠白底，预乘应得 r=1.00，双重预乘
##      blend_mix 会得 r=0.75。这条是"玩家看到什么"的量化对照，headless 下跳过。
##
## 跑法：
##   <GODOT_DIR> --headless --path Project/project-keynes \
##       --script res://tests/rendering/fog_premultiply_blit_test.gd
## 退出码 0 = 全过；1 = 有失败（每条失败同时 push_error）。

const FogScript := preload("res://scripts/rendering/fog_of_war_layer.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fog := FogScript.new()
	# 100% 档要在 _ready 之前定下来，否则 _ensure_nodes 会先按默认档建 SubViewport。
	fog.set_render_scale(100)
	root.add_child(fog)
	_expect("100% draws the fog mesh directly on the canvas",
		fog._sub_viewport == null and fog._blit_sprite == null
		and fog.get_node_or_null("FogBlit") == null
		and fog._mesh_inst.get_parent() == fog)
	# 本用例只钉 blit 的混合模式，z 一个数没动。层是绝对 z，blit 自己仍是
	# z_as_relative 默认 true + z_index 12 ⇒ <100% 档有效 z 是 12+12 = 24。
	# 那半条属于图层契约的后续批次，这里只防止改 blit 时把它带歪。
	_expect("fog keeps absolute z ordering",
		not fog.z_as_relative and fog.z_index == 12 and fog._mesh_inst.z_index == 0)

	fog.set_render_scale(75)
	_check_scaled(fog, 75)
	fog.set_render_scale(50)
	_check_scaled(fog, 50)

	# 退回 100%：blit 与 SubViewport 必须一起释放，网格回主画布（不留孤儿节点）。
	fog.set_render_scale(100)
	_expect("returning to 100% releases the blit and the sub-viewport",
		fog._sub_viewport == null and fog._blit_sprite == null
		and fog.get_node_or_null("FogBlit") == null
		and fog._mesh_inst.get_parent() == fog)
	# 再进 50%：材质不能因为上一轮释放而丢（每次重建都要重新挂）。
	fog.set_render_scale(50)
	_check_scaled(fog, 50)
	fog.queue_free()
	await process_frame

	await _check_pixel_composite()
	print("fog premultiply blit: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_scaled(fog: Node, percent: int) -> void:
	var sprite = fog._blit_sprite
	var target = fog._sub_viewport
	var material = sprite.material if sprite != null else null
	_expect("%d%% blits through a sub-viewport" % percent,
		sprite != null and target != null and target.transparent_bg
		and sprite.texture == target.get_texture()
		and fog._mesh_inst.get_parent() == target)
	_expect("%d%% blit material is a premultiplied-alpha CanvasItemMaterial" % percent,
		material is CanvasItemMaterial
		and material.blend_mode == CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA)
	_expect("%d%% blit stays on the main canvas above the world" % percent,
		sprite != null and sprite.top_level and sprite.z_index == 12)


## 像素对照：与 FogRenderTarget.build() 同样的节点构造，只差 blend mode。
func _check_pixel_composite() -> void:
	if DisplayServer.get_name() == "headless":
		print("  [SKIP] pixel composite needs a rendering device (headless)")
		return
	for mode in [CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA, CanvasItemMaterial.BLEND_MODE_MIX]:
		var output := SubViewport.new()
		output.size = Vector2i(64, 64)
		output.disable_3d = true
		output.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(output)
		var background := ColorRect.new()
		background.color = Color.WHITE
		background.size = Vector2(64, 64)
		output.add_child(background)

		var inner := SubViewport.new()
		inner.size = Vector2i(64, 64)
		inner.transparent_bg = true
		inner.disable_3d = true
		inner.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		output.add_child(inner)
		var half_red := ColorRect.new()
		half_red.color = Color(1.0, 0.0, 0.0, 0.5)
		half_red.size = Vector2(64, 64)
		inner.add_child(half_red)

		var blit := Sprite2D.new()
		blit.centered = false
		blit.texture = inner.get_texture()
		var material := CanvasItemMaterial.new()
		material.blend_mode = mode
		blit.material = material
		output.add_child(blit)

		for i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var pixel := output.get_texture().get_image().get_pixel(32, 32)
		if mode == CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA:
			# 预乘：dst = 0.5 + 1.0 * (1 - 0.5) = 1.0
			_expect("premultiplied blit shows the true 50% red over white (r=1.00)",
				absf(pixel.r - 1.0) < 0.02)
			print("    premult pixel = %s" % pixel)
		else:
			# 双重预乘（旧行为）：dst = 0.5 * 0.5 + 1.0 * (1 - 0.5) = 0.75
			_expect("blend_mix double-premultiplies the same texture (r=0.75)",
				absf(pixel.r - 0.75) < 0.02)
			print("    blend_mix pixel = %s" % pixel)
		output.queue_free()
		await process_frame


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
