extends DossierChart
class_name MilitaryCodexGrid

## Unit codex: one technology-tree plate (card_known.png) per unit type with its
## sticker, class/era, attack/defense/speed and the Q1–Q5 equipment ladder.
## Drawn in one control because the catalog has ~25 rows and the player UI may not
## instantiate controls at runtime.

const PLATE_PATH := "res://assets/ui/technology_tree_v1/card_known.png"
const PLATE_MARGIN := 30.0
const MIN_PLATE_WIDTH := 228.0
const PLATE_HEIGHT := 70.0
const GAP := 8.0
const ICON := 42.0
const PIP := 13.0

var _cards: Array = []
var _rects: Array = []
var _hover := -1
var _plate: StyleBoxTexture


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS


func set_cards(cards: Array) -> void:
	_cards = cards
	_relayout()
	queue_redraw()


func card_count() -> int:
	return _cards.size()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_relayout()
		NOTIFICATION_MOUSE_EXIT:
			if _hover >= 0:
				_hover = -1
				queue_redraw()


func _relayout() -> void:
	var width := maxf(MIN_PLATE_WIDTH, size.x)
	var columns := maxi(1, int(floor((width + GAP) / (MIN_PLATE_WIDTH + GAP))))
	var plate_width := (width - GAP * float(columns - 1)) / float(columns)
	_rects.clear()
	for index in range(_cards.size()):
		var column := index % columns
		var row := index / columns
		_rects.append(Rect2(Vector2(float(column) * (plate_width + GAP),
			float(row) * (PLATE_HEIGHT + GAP)), Vector2(plate_width, PLATE_HEIGHT)))
	var rows := ceili(float(_cards.size()) / float(columns))
	var wanted := maxf(PLATE_HEIGHT, float(rows) * (PLATE_HEIGHT + GAP) - GAP)
	if absf(custom_minimum_size.y - wanted) > 0.5:
		custom_minimum_size.y = wanted
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseMotion:
		return
	var hit := -1
	for index in range(_rects.size()):
		if (_rects[index] as Rect2).has_point((event as InputEventMouseMotion).position):
			hit = index
			break
	if hit != _hover:
		_hover = hit
		tooltip_text = _tooltip(_cards[hit]) if hit >= 0 else ""
		queue_redraw()


static func _tooltip(card: Dictionary) -> String:
	var lines := PackedStringArray(["%s · %s" % [String(card.get("name", "")),
		String(card.get("subtitle", ""))]])
	var description := String(card.get("description", ""))
	if not description.is_empty():
		lines.append(description)
	lines.append("攻 %s · 防 %s · 速 %s · 训练 %s" % [String(card.get("attack_text", "")),
		String(card.get("defense_text", "")), String(card.get("speed_text", "")),
		String(card.get("training_text", ""))])
	for slot in card.get("equipment", []):
		lines.append(String(slot))
	return "\n".join(lines)


func _plate_style() -> StyleBoxTexture:
	if _plate == null:
		_plate = StyleBoxTexture.new()
		_plate.texture = load(PLATE_PATH) as Texture2D
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			_plate.set_texture_margin(side, PLATE_MARGIN)
	return _plate


func _draw() -> void:
	var plate := _plate_style()
	for index in range(mini(_rects.size(), _cards.size())):
		var rect: Rect2 = _rects[index]
		var card: Dictionary = _cards[index]
		plate.modulate_color = Color(1.0, 0.97, 0.9) if index == _hover else Color.WHITE
		draw_style_box(plate, rect)
		var icon_rect := Rect2(rect.position + Vector2(10.0, (rect.size.y - ICON) * 0.5),
			Vector2(ICON, ICON))
		IconCatalog.draw_icon(self, StringName(card.get("icon", "military.unit.line")), icon_rect)
		var x := icon_rect.end.x + 8.0
		var text_width := rect.end.x - x - 12.0
		_text(Vector2(x, rect.position.y + 23.0), _fit_text(String(card.get("name", "")), 14,
			text_width - 74.0, "sans_strong"), 14, UITokens.DOSSIER_INK, "sans_strong")
		_text(Vector2(x, rect.position.y + 39.0), _fit_text(String(card.get("subtitle", "")), 11,
			text_width), 11, UITokens.DOSSIER_INK_MUTED)
		var stats := "攻 %s  防 %s  速 %s" % [String(card.get("attack_text", "")),
			String(card.get("defense_text", "")), String(card.get("speed_text", ""))]
		_text(Vector2(x, rect.position.y + 56.0), _fit_text(stats, 12, text_width), 12,
			UITokens.DOSSIER_INK_SOFT, "sans_strong")
		if bool(card.get("militia", false)):
			_text(Vector2(rect.end.x - 74.0, rect.position.y + 23.0), "无需装备", 11,
				UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_RIGHT, 62.0)
		else:
			_draw_ladder(Vector2(rect.end.x - 12.0, rect.position.y + 12.0),
				int(card.get("min_quality", 1)))


## Five quality pips, filled from the unit's minimum equipment quality upward.
func _draw_ladder(top_right: Vector2, min_quality: int) -> void:
	for quality in range(1, 6):
		var pip := Rect2(top_right + Vector2(-float(6 - quality) * (PIP + 1.0), 0.0),
			Vector2(PIP, PIP))
		var usable := quality >= min_quality
		draw_rect(pip, Color(UITokens.DOSSIER_BRASS, 0.85) if usable else UITokens.DOSSIER_TRACK)
		draw_rect(pip, Color(UITokens.DOSSIER_INK_SOFT, 0.45), false, 1.0)
	_text(top_right + Vector2(-5.0 * (PIP + 1.0), PIP + 11.0), "≥Q%d" % min_quality, 10,
		UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_RIGHT, 5.0 * (PIP + 1.0))
