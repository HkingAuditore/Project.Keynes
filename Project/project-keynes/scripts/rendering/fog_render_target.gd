extends RefCounted

## Scaled fog keeps its last texture until the animation, camera or published mask needs a draw.
const IDLE_REDRAW_INTERVAL := 1.0 / 15.0
var viewport: SubViewport
var blit: Sprite2D
var elapsed := 0.0
var dirty := true
var _revision := -1


func build(layer: CanvasItem, mesh: MeshInstance2D) -> void:
	if viewport != null:
		return
	viewport = SubViewport.new()
	viewport.name = "FogHalfRes"
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.gui_disable_input = true
	viewport.size = Vector2i(2, 2)
	layer.add_child(viewport)
	if mesh.get_parent() == null:
		viewport.add_child(mesh)
	else:
		mesh.reparent(viewport, false)
	# 上采样用 Sprite2D 而不是 TextureRect：Control 的 transform 不是可写属性
	# （只能改 position/scale/size，且受 anchors 约束），而 Sprite2D 直接吃
	# canvas 变换的逆，能精确铺满屏幕。
	# 它留在主画布（canvas 0）里才能参与 z_index 排序：迷雾要在世界之上、UI 之下；
	# 换 CanvasLayer 会跳出画布 0，反而盖住 HUD。
	blit = Sprite2D.new()
	blit.name = "FogBlit"
	blit.centered = false
	blit.texture = viewport.get_texture()
	blit.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	blit.top_level = true
	blit.z_index = 12
	blit.visible = false
	layer.add_child(blit)


func drop(layer: CanvasItem, mesh: MeshInstance2D) -> void:
	if viewport == null:
		return
	mesh.reparent(layer, false)
	layer.remove_child(blit)
	blit.queue_free()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	layer.remove_child(viewport)
	viewport.queue_free()
	blit = null
	viewport = null


func sync_visibility(layer: CanvasItem, percent: int) -> void:
	if viewport == null:
		return
	var drawn := layer.is_visible_in_tree()
	blit.visible = drawn
	# Render on the first frame after activation. A viewport that waits for a
	# visible consumer can leave the newly switched fog blank for one frame.
	dirty = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if drawn else SubViewport.UPDATE_DISABLED
	if drawn:
		_sync_transform(layer, percent)


func needs_draw(layer: CanvasItem, percent: int, world: WorldData) -> bool:
	_sync_transform(layer, percent)
	var revision := world.fog_texture_revision if world != null else -1
	# A texture can receive a new visibility mask without changing object identity.
	# Standalone callers without a publisher keep drawing their external inputs.
	if dirty or revision != _revision or world == null:
		elapsed = 0.0
	elif elapsed >= IDLE_REDRAW_INTERVAL:
		elapsed = fmod(elapsed, IDLE_REDRAW_INTERVAL)
	else:
		return false
	dirty = false
	_revision = revision
	return true


## Scale the transform by the actual target dimensions to preserve alignment and
## screen-space effects at odd window sizes.
func _sync_transform(layer: CanvasItem, percent: int) -> void:
	if viewport == null or blit == null:
		return
	var vp := layer.get_viewport()
	if vp == null:
		return
	var view := vp.get_visible_rect()
	if view.size.x <= 0.0 or view.size.y <= 0.0:
		return
	var fraction := float(percent) / 100.0
	var physical_size := view.size * vp.get_stretch_transform().get_scale().abs()
	var target_size := Vector2i(physical_size * fraction).max(Vector2i(2, 2))
	if viewport.size != target_size:
		dirty = true
		viewport.size = target_size
	var scale := Vector2(target_size) / view.size
	var downsample := Transform2D(Vector2(scale.x, 0.0), Vector2(0.0, scale.y), -view.position * scale)
	var canvas := downsample * vp.canvas_transform
	if viewport.canvas_transform != canvas:
		dirty = true
		viewport.canvas_transform = canvas
	var blit_transform := canvas.affine_inverse()
	if blit.transform != blit_transform:
		blit.transform = blit_transform
