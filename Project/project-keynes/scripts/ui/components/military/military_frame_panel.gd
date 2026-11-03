extends PanelContainer
class_name MilitaryFramePanel

## PanelContainer drawn with the ideology paper materials: an ivory_sheet fill under a
## nine-sliced edge bitmap (edge_jade / edge_cinnabar_gold). StyleBoxTexture draws
## margins at source pixel size, so the frame is drawn under a scale transform to
## keep a thin edge on a 1086px source.

const IVORY_SHEET := "res://assets/ui/ideology_paper_v3/ivory_sheet.png"
const IVORY_REGION := Rect2(8, 16, 496, 309)
const EDGES := {
	"jade": "res://assets/ui/ideology_paper_v3/edge_jade.png",
	"cinnabar": "res://assets/ui/ideology_paper_v3/edge_cinnabar_gold.png",
}
const EDGE_MARGIN := 48.0
const IVORY_MARGIN := 24.0

@export_enum("jade", "cinnabar") var edge := "jade":
	set(value):
		edge = value
		_edge_style = null
		queue_redraw()
@export var frame_scale := 0.42:
	set(value):
		frame_scale = maxf(0.1, value)
		_apply_content_margin()
		queue_redraw()
## Content inset. The nine-sliced edge is drawn at `EDGE_MARGIN * frame_scale`
## pixels, so a fixed 12px bottom margin let children (the army order row, the
## peace submit button) slide underneath the frame. Anything below the painted
## edge is invisible, so the inset is derived from it.
@export var content_margin := Vector4(0, 0, 0, 0):
	set(value):
		content_margin = value
		_apply_content_margin()

var _edge_style: StyleBoxTexture
var _paper_style: StyleBoxTexture


func _init() -> void:
	_apply_content_margin()


## 默认内边距：左右/下让开绘制出来的边框（≈20px）+ 呼吸，顶部留 14px。
func _default_content_margin() -> Vector4:
	var border := ceilf(EDGE_MARGIN * frame_scale)
	return Vector4(border + 2.0, 14.0, border + 2.0, border + 8.0)


func _apply_content_margin() -> void:
	var margins: Vector4 = content_margin
	if margins == Vector4(0, 0, 0, 0):
		margins = _default_content_margin()
	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = margins.x
	empty.content_margin_top = margins.y
	empty.content_margin_right = margins.z
	empty.content_margin_bottom = margins.w
	add_theme_stylebox_override("panel", empty)


func _styles() -> void:
	if _paper_style == null:
		_paper_style = StyleBoxTexture.new()
		_paper_style.texture = load(IVORY_SHEET) as Texture2D
		_paper_style.region_rect = IVORY_REGION
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			_paper_style.set_texture_margin(side, IVORY_MARGIN)
	if _edge_style == null:
		_edge_style = StyleBoxTexture.new()
		_edge_style.texture = load(String(EDGES.get(edge, EDGES.jade))) as Texture2D
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			_edge_style.set_texture_margin(side, EDGE_MARGIN)


func _draw() -> void:
	if size.x < 8.0 or size.y < 8.0:
		return
	_styles()
	var inset := Vector2(3.0, 3.0)
	draw_style_box(_paper_style, Rect2(inset, size - inset * 2.0))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(frame_scale, frame_scale))
	draw_style_box(_edge_style, Rect2(Vector2.ZERO, size / frame_scale))
	draw_set_transform_matrix(Transform2D.IDENTITY)
