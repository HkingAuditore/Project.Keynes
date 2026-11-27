extends Control
class_name PapercutAtlasBackdrop

const DESK := preload("res://assets/ui/tabletop/desk.webp")
const HARBOUR := preload("res://assets/ui/tabletop/harbour.webp")
const QUAY := preload("res://assets/ui/tabletop/quay.webp")
const SHIP := preload("res://assets/ui/tabletop/moored_ship.webp")
const PENNANT := preload("res://assets/ui/tabletop/pennant.webp")
const SMITH := preload("res://assets/ui/tabletop/smith.webp")
const PORTER := preload("res://assets/ui/tabletop/porter.webp")
const VENDOR := preload("res://assets/ui/tabletop/vendor.webp")

var _home := true
var _turn := 1.0
var _opening := 0.0
var _phase := 0.0
var _parallax := Vector2.ZERO
var _turn_tween: Tween


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	clip_contents = true
	visibility_changed.connect(_sync_motion)
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		settings.settings_changed.connect(func(_values: Dictionary) -> void: _sync_motion())
	resized.connect(queue_redraw)
	_sync_motion()


func _sync_motion() -> void:
	set_process(_home and is_visible_in_tree() and not UIAnimation.reduced_motion())
	if UIAnimation.reduced_motion():
		_opening = 1.0
		_parallax = Vector2.ZERO
		_phase = 0.0
	queue_redraw()


func set_page_mode(page: String) -> void:
	var home := page == "home"
	if home != _home:
		if _turn_tween != null:
			_turn_tween.kill()
		_home = home
		var target := 1.0 if home else 0.0
		if UIAnimation.reduced_motion():
			_set_turn(target)
		else:
			_turn_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			_turn_tween.tween_method(_set_turn, _turn, target, 0.35)
	_sync_motion()


func _set_turn(value: float) -> void:
	_turn = value
	queue_redraw()


func _process(delta: float) -> void:
	_opening = minf(_opening + delta / 0.65, 1.0)
	_phase = fmod(_phase + delta, TAU * 2.0)
	var center := Vector2(0.5, 0.5)
	var aim := (get_local_mouse_position() / size.max(Vector2.ONE) - center).clamp(-center, center)
	_parallax = _parallax.lerp(aim * 7.0, 1.0 - exp(-delta * 5.0))
	queue_redraw()


func _cover(texture: Texture2D, zoom: float = 1.0) -> Rect2:
	var extent := texture.get_size() * maxf(size.x / texture.get_width(), size.y / texture.get_height()) * zoom
	return Rect2((size - extent) * 0.5, extent)


func _draw() -> void:
	if _turn < 1.0:
		draw_texture_rect(DESK, _cover(DESK, 1.0 + _turn * 0.035), false)
	if _turn <= 0.0:
		return
	var tint := Color(1.0, 1.0, 1.0, _turn)
	var stage := _cover(HARBOUR, 1.0 + (1.0 - _turn) * 0.08)
	draw_texture_rect(HARBOUR, stage, false, tint)
	var unit := minf(size.y, size.x * 0.8)
	# 枢轴与分层位图均取自 1672 × 941 的同一舞台原画。
	var art_scale := stage.size / HARBOUR.get_size()
	var quay_rise := smoothstep(0.0, 0.66, _opening)
	var ship_rise := smoothstep(0.16, 0.84, _opening)
	_draw_standee(QUAY, stage.position + Vector2(465, 717) * art_scale, art_scale, quay_rise, tint)
	_draw_standee(SHIP, stage.position + Vector2(1304, 716) * art_scale, art_scale, ship_rise, tint)
	var attachment := stage.position + Vector2(1340, 717 - 668 * quay_rise) * art_scale
	draw_set_transform(attachment, sin(_phase) * 0.016)
	draw_texture_rect(PENNANT, Rect2(Vector2.ZERO, stage.size.x * Vector2(0.126, 0.030 * quay_rise)), false, tint)
	draw_set_transform(Vector2.ZERO)
	_draw_actor(VENDOR, Vector2(0.59, 0.60), unit * 0.26, 0.0, true)
	_draw_actor(PORTER, Vector2(0.71, 0.86), unit * 0.35, 0.12, true)
	_draw_actor(SMITH, Vector2(0.48, 0.94), unit * 0.44, 0.24, false)


func _draw_standee(texture: Texture2D, foot: Vector2, art_scale: Vector2, rise: float, tint: Color) -> void:
	var extent := texture.get_size() * art_scale * Vector2(1.0, rise)
	if extent.y > 0.1:
		draw_texture_rect(texture, Rect2(foot - Vector2(0.0, extent.y), extent), false, tint)


func _draw_actor(texture: Texture2D, feet: Vector2, height: float, delay: float, flipped: bool) -> void:
	var rise := smoothstep(delay, delay + 0.72, _opening)
	if rise <= 0.001:
		return
	var base := feet * size + _parallax * feet.y + Vector2(0.0, (1.0 - _turn) * 16.0)
	var extent := texture.get_size() * (height / texture.get_height())
	draw_set_transform(base, 0.0, Vector2(extent.x * 0.40, height * 0.025))
	draw_circle(Vector2.ZERO, 1.0, Color(0.14, 0.10, 0.08, 0.24 * rise * _turn), true, -1.0, true)
	draw_set_transform(base, 0.0, Vector2(-1.0 if flipped else 1.0, rise))
	draw_texture_rect(texture, Rect2(Vector2(-extent.x * 0.5, -extent.y), extent), false, Color(1, 1, 1, _turn))
	draw_set_transform(Vector2.ZERO)
