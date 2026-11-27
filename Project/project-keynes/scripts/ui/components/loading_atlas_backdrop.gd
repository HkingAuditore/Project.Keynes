extends Control

const DESK := preload("res://assets/ui/tabletop/desk.webp")
const SCENERY := [
	preload("res://assets/ui/tabletop/mountains.webp"),
	preload("res://assets/ui/tabletop/fields.webp"),
	preload("res://assets/ui/tabletop/market.webp"),
	preload("res://assets/ui/tabletop/barge.webp"),
]
const FEET := [Vector2(0.45, 0.44), Vector2(0.53, 0.57), Vector2(0.38, 0.58), Vector2(0.63, 0.66)]
const WIDTHS := [0.55, 0.68, 0.32, 0.25]
const STARTS := [0.0, 0.24, 0.58, 0.84]

var _progress := 0.0
var _seed_shift := 0.0
var restoring := false


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_layout_state(state: Dictionary) -> void:
	_seed_shift = float(posmod(int(state.get("initial_seed", state.get("seed", 0))), 9) - 4) * 0.004
	queue_redraw()


func set_loading_progress(fraction: float) -> void:
	_progress = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var cover := DESK.get_size() * maxf(size.x / DESK.get_width(), size.y / DESK.get_height())
	draw_texture_rect(DESK, Rect2((size - cover) * 0.5, cover), false)
	var stage_width := minf(size.x, size.y * 1.85)
	for i in SCENERY.size():
		var texture: Texture2D = SCENERY[i]
		var rise := smoothstep(STARTS[i], STARTS[i] + 0.15, _progress)
		if UIAnimation.reduced_motion() or restoring:
			rise = 1.0
		if rise <= 0.0:
			continue
		var foot: Vector2 = FEET[i]
		var base := Vector2(size.x * 0.5 + (foot.x - 0.5 + _seed_shift) * stage_width, size.y * foot.y)
		var extent := texture.get_size() * (stage_width * float(WIDTHS[i]) / texture.get_width())
		extent.y *= rise
		draw_texture_rect(texture, Rect2(base - Vector2(extent.x * 0.5, extent.y), extent), false)
