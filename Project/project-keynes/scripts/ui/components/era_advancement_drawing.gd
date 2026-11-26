extends RefCounted

## Draws the era advancement status and its requirements on the panel's canvas.


static func _draw_advancement(panel, x: float, w: float) -> void:
	var m: Dictionary = panel._model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var display := UITokens.dossier_font("serif")
	panel._text(Vector2(x, panel.KICKER_Y), "时代晋升", strong, panel.SIZE_BODY, UITokens.DOSSIER_OXBLOOD, w - 70.0)
	if not bool(m.get("ok", false)):
		panel._text(Vector2(x, panel.TITLE_Y), "数据暂不可用", display, panel.SIZE_TITLE, UITokens.DOSSIER_INK_MUTED, w)
		return
	var status := String(m.get("status", ""))
	var current: Dictionary = m.get("current", {})
	var next: Dictionary = m.get("next", {})
	var chip_w: float = panel._draw_status_chip(x + w, status)
	var era_line := String(current.get("name", "")) if next.is_empty() \
		else "%s → %s" % [String(current.get("name", "")), String(next.get("name", ""))]
	panel._text(Vector2(x, panel.TITLE_Y), era_line, display, panel.SIZE_TITLE, UITokens.DOSSIER_INK, w - chip_w - 12.0)
	if status == "max":
		panel._draw_max(x, w)
		return
	panel._draw_band(x, w, status)
	panel._draw_conditions(x, w)
	panel._draw_costs(x, w)
	panel._draw_buffs(x, w, panel._buff_head_y(), "晋升后获得")
	var rule_y: float = panel._rows.rule_y
	panel._canvas.draw_line(Vector2(x, rule_y), Vector2(x + w, rule_y), Color(UITokens.DOSSIER_RULE, 0.75), 1.0)
	var hint: String = panel.action_hint()
	if not hint.is_empty():
		var hint_right: float = panel._action.position.x - panel.HINT_GAP if panel._action.visible else x + w
		if panel._reward_link != null and panel._reward_link.visible:
			hint_right = minf(hint_right, panel._reward_link.position.x - 10.0)
		# 文字视觉中心（基线上方 ascent/2）对齐按钮中心。
		var centre: float = float(panel._rows.action_top) + panel.ACTION_H * 0.5
		var baseline := centre + sans.get_ascent(panel.SIZE_MINOR) * 0.5 - 1.0
		panel._text(Vector2(x, baseline), hint, sans, panel.SIZE_MINOR,
			UITokens.DOSSIER_OXBLOOD if not panel._error.is_empty() else UITokens.DOSSIER_INK_MUTED,
			maxf(0.0, hint_right - x), HORIZONTAL_ALIGNMENT_LEFT, hint)

static func _status_colour(panel, status: String) -> Color:
	match status:
		"ready", "completing", "max": return UITokens.DOSSIER_VERDIGRIS
		"locked": return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_INK_SOFT

## 状态签右对齐在时代行基线上，返回其宽度。
static func _draw_status_chip(panel, right: float, status: String) -> float:
	var sans := UITokens.dossier_font("sans_strong")
	var text := String(panel._model.get("status_chip", ""))
	if text.is_empty():
		return 0.0
	var colour: Color = panel._status_colour(status)
	var text_w := sans.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, panel.SIZE_MINOR).x
	var rect := Rect2(right - text_w - 18.0, panel.TITLE_Y - 18.0, text_w + 18.0, 24.0)
	panel._chip_style.bg_color = Color(colour, 0.08)
	panel._chip_style.border_color = Color(colour, 0.55)
	panel._canvas.draw_style_box(panel._chip_style, rect)
	panel._canvas.draw_string(sans, Vector2(rect.position.x + 9.0, panel.TITLE_Y - 1.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, panel.SIZE_MINOR, colour)
	panel._drawn.append(text)
	return rect.size.x

static func _draw_band(panel, x: float, w: float, status: String) -> void:
	var current: Dictionary = panel._model.get("current", {})
	var next: Dictionary = panel._model.get("next", {})
	var progress := clampf(panel._shown_progress, 0.0, 1.0)
	var filling := status in ["purchasing", "paused", "completing"]
	var ring_ink := Color(UITokens.DOSSIER_INK_SOFT, 0.5)
	var accent := UITokens.DOSSIER_BRASS if status != "paused" else UITokens.DOSSIER_UMBER
	# 一组居中的「旧徽 → 双刻箭 → 主徽」。主徽是视觉重心，进度用它的手绘笔锋弧表达；
	# 中间不再画横贯整行的进度轨。
	var old_side: float = panel.OLD_EMBLEM
	var new_side: float = panel.NEW_EMBLEM
	var chevron_w := 22.0
	var gap := 14.0
	var group: float = old_side + gap + chevron_w + gap + new_side
	var left := x + maxf(0.0, (w - group) * 0.5)
	var old_center := Vector2(left + old_side * 0.5, panel.BAND_CENTER)
	var new_center := Vector2(left + group - new_side * 0.5, panel.BAND_CENTER)
	panel._canvas.draw_arc(old_center, old_side * 0.5 + 4.0, 0.0, TAU, 64, ring_ink, 1.5, true)
	var old_icon: Texture2D = panel._era_texture(String(current.get("id", "")))
	if old_icon != null:
		panel._canvas.draw_texture_rect(old_icon, Rect2(old_center - Vector2.ONE * old_side * 0.5,
			Vector2.ONE * old_side), false, Color(1, 1, 1, 0.86))
	# 双刻箭：两枚手刻的三角刻痕，代替一条长直线。
	var chev_x: float = left + old_side + gap
	for i in range(2):
		var cx: float = chev_x + float(i) * 9.0
		var ink := Color(UITokens.DOSSIER_INK_SOFT, 0.5 - float(i) * 0.14)
		panel._canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(cx, panel.BAND_CENTER - 7.0),
			Vector2(cx + 8.0, panel.BAND_CENTER),
			Vector2(cx, panel.BAND_CENTER + 7.0),
			Vector2(cx + 3.2, panel.BAND_CENTER)]), ink)
	# 主徽底环：淡墨细圈，让笔锋弧有落笔的位置。
	panel._canvas.draw_arc(new_center, panel.RING_RADIUS, 0.0, TAU, 96, Color(UITokens.DOSSIER_INK_SOFT, 0.16), 4.0, true)
	if filling and progress > 0.0:
		panel._draw_brush_ring(new_center, panel.RING_RADIUS, progress, accent)
	var new_icon: Texture2D = panel._era_texture(String(next.get("id", "")))
	if new_icon != null:
		var tint := Color.WHITE if status != "locked" else Color(0.82, 0.78, 0.72, 0.9)
		panel._canvas.draw_texture_rect(new_icon, Rect2(new_center - Vector2.ONE * new_side * 0.5,
			Vector2.ONE * new_side), false, tint)

## 手绘笔锋弧：由粗到细分段铺，末端收成尖锋，读起来像蘸墨画的一圈，而不是仪表刻度。
static func _draw_brush_ring(panel, centre: Vector2, radius: float, ratio: float, colour: Color) -> void:
	var steps := maxi(24, int(96.0 * ratio))
	var start := -PI * 0.5
	var sweep := TAU * clampf(ratio, 0.0, 1.0)
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var width := lerpf(5.2, 2.2, t0)
		var alpha := lerpf(0.95, 0.55, t0)
		panel._canvas.draw_arc(centre, radius, start + sweep * t0, start + sweep * t1, 6,
			Color(colour, alpha), width, true)
	# 起笔一点、收笔尖锋：避免圆弧两端是生硬的平口。
	var head := start
	panel._canvas.draw_circle(centre + Vector2(cos(head), sin(head)) * radius, 3.4,
		Color(colour, 0.95), true, -1.0, true)
	var tail := start + sweep
	var tip := centre + Vector2(cos(tail), sin(tail)) * radius
	var tangent := Vector2(-sin(tail), cos(tail))
	var normal := Vector2(cos(tail), sin(tail))
	panel._canvas.draw_colored_polygon(PackedVector2Array([
		tip + normal * 2.4,
		tip - normal * 2.4,
		tip + tangent * 5.0]), Color(colour, 0.75))

static func _draw_conditions(panel, x: float, w: float) -> void:
	var m: Dictionary = panel._model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var numeral := UITokens.dossier_font("numeral")
	var rows: Array = m.get("conditions", [])
	var tile_w := floorf((w - panel.COND_GAP) * 0.5)
	for i in range(mini(rows.size(), 4)):
		var row: Dictionary = rows[i]
		var met := bool(row.get("met", false))
		var rect := Rect2(x + float(i % 2) * (tile_w + panel.COND_GAP),
			panel.COND_TOP + float(i / 2) * (panel.COND_H + panel.COND_GAP), tile_w, panel.COND_H)
		panel._chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		panel._chip_style.border_color = Color(UITokens.DOSSIER_VERDIGRIS, 0.5) if met \
			else Color(UITokens.DOSSIER_RULE, 0.5)
		panel._canvas.draw_style_box(panel._chip_style, rect)
		var baseline := rect.position.y + 22.0
		IconCatalog.draw_icon(panel._canvas, &"control.checkbox_checked" if met else &"control.checkbox_unchecked",
			Rect2(rect.position.x + 7.0, rect.position.y + 9.0, 16.0, 16.0), 1.0 if met else 0.7)
		# 条件行不再挂装饰图标：勾选框 + 名称 + 数值已经够读，多一个图标只会把名称挤成省略号。
		var value := String(row.get("value_text", row.get("text", "")))
		var value_w := numeral.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, panel.SIZE_MINOR).x
		var colour: Color = UITokens.DOSSIER_VERDIGRIS if met else UITokens.DOSSIER_INK
		var label := String(row.get("label", ""))
		panel._text(Vector2(rect.position.x + 30.0, baseline), label, strong if met else sans, panel.SIZE_MINOR, colour,
			rect.size.x - 30.0 - value_w - 12.0)
		panel._text(Vector2(rect.end.x - value_w - 8.0, baseline), value, numeral, panel.SIZE_MINOR, colour, value_w + 1.0)
		# 勾选框已经表达满足与否，不再用 tooltip 复述「已满足 / 未满足」。
		var tip := String(row.get("tooltip", ""))
		if not tip.is_empty():
			panel._region(rect, tip)

static func _draw_costs(panel, x: float, w: float) -> void:
	var m: Dictionary = panel._model
	var strong := UITokens.dossier_font("sans_strong")
	var sans := UITokens.dossier_font("sans")
	var numeral := UITokens.dossier_font("numeral")
	var costs: Array = m.get("costs", [])
	if costs.is_empty():
		return
	panel._text(Vector2(x, panel.COST_HEAD_Y), "晋升物资", strong, panel.SIZE_BODY, UITokens.DOSSIER_INK, w)
	var overflow: bool = costs.size() > panel.MAX_COST_CHIPS
	var shown: int = panel.MAX_COST_CHIPS - 1 if overflow else costs.size()
	# 签宽按实际签数均分：固定 4 等分时中文名（如「采集植物食物」）会被截断。
	var slots: int = panel.MAX_COST_CHIPS if overflow else maxi(1, costs.size())
	var chip_w: float = floorf((w - 6.0 * float(slots - 1)) / float(slots))
	for i in range(shown):
		var row: Dictionary = costs[i]
		var rect := Rect2(x + float(i) * (chip_w + 6.0), panel.COST_TOP, chip_w, panel.COST_H)
		var done := bool(row.get("done", false))
		panel._chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		panel._chip_style.border_color = Color(UITokens.DOSSIER_VERDIGRIS, 0.5) if done \
			else Color(UITokens.DOSSIER_RULE, 0.5)
		panel._canvas.draw_style_box(panel._chip_style, rect)
		IconCatalog.draw_icon(panel._canvas, StringName(row.get("icon", &"system.unknown")),
			Rect2(rect.position.x + 5.0, rect.position.y + 9.0, 22.0, 22.0))
		var good_name := String(row.get("name", ""))
		var value := String(row.get("value_text", ""))
		var tx := rect.position.x + 31.0
		var inner := rect.end.x - 6.0 - tx
		panel._text(Vector2(tx, rect.position.y + 17.0), good_name, sans, panel.SIZE_MINOR, UITokens.DOSSIER_INK,
			inner, HORIZONTAL_ALIGNMENT_LEFT,
			"%s：国库 %s / 需求 %s" % [good_name, String(row.get("stock_text", "0")),
				String(row.get("required_text", "0"))])
		panel._text(Vector2(tx, rect.position.y + 30.0), value, numeral, panel.SIZE_MINOR,
			UITokens.DOSSIER_VERDIGRIS if done else UITokens.DOSSIER_INK, inner, HORIZONTAL_ALIGNMENT_RIGHT)
		var bar := Rect2(rect.position.x + 5.0, rect.end.y - 4.0, chip_w - 10.0, 2.0)
		panel._canvas.draw_rect(bar, UITokens.DOSSIER_TRACK)
		panel._canvas.draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(row.get("ratio", 0.0)), bar.size.y)),
			UITokens.DOSSIER_VERDIGRIS if done else UITokens.DOSSIER_BRASS)
		panel._region(rect, "%s：国库 %s / 需求 %s" % [good_name, String(row.get("stock_text", "0")),
			String(row.get("required_text", "0"))])
	if overflow:
		var rect := Rect2(x + float(shown) * (chip_w + 6.0), panel.COST_TOP, chip_w, panel.COST_H)
		panel._chip_style.bg_color = UITokens.DOSSIER_PAPER_SHADE
		panel._chip_style.border_color = Color(UITokens.DOSSIER_RULE, 0.5)
		panel._canvas.draw_style_box(panel._chip_style, rect)
		var lines := PackedStringArray()
		for i in range(shown, costs.size()):
			var row: Dictionary = costs[i]
			lines.append("%s：%s" % [String(row.get("name", "")), String(row.get("value_text", ""))])
		panel._text(Vector2(rect.position.x, rect.position.y + 26.0), "+%d 种" % (costs.size() - shown), sans,
			panel.SIZE_BODY, UITokens.DOSSIER_INK_SOFT, chip_w, HORIZONTAL_ALIGNMENT_CENTER)
		panel._region(rect, "\n".join(lines))

## 加成逐条全列：≤4 条单列，否则两列（超出两列容量时三列），每条截断后全文进提示。
static func _draw_buffs(panel, x: float, w: float, head_y: float, heading: String) -> void:
	var sans := UITokens.dossier_font("sans")
	var buffs: PackedStringArray = panel._model.get("buffs", PackedStringArray())
	if buffs.is_empty():
		return
	panel._text(Vector2(x, head_y), heading, sans, panel.SIZE_MINOR, UITokens.DOSSIER_BRASS.darkened(0.25), w)
	var columns := 1 if buffs.size() <= 4 else (2 if buffs.size() <= 2 * panel.BUFF_MAX_ROWS else 3)
	var rows := int(ceil(float(buffs.size()) / float(columns)))
	var col_w := floorf((w - 12.0 * float(columns - 1)) / float(columns))
	for i in range(buffs.size()):
		var col := i / rows
		var row := i % rows
		var pos := Vector2(x + float(col) * (col_w + 12.0), head_y + 22.0 + float(row) * panel.BUFF_LINE)
		panel._text(pos, "· " + String(buffs[i]), sans, panel.SIZE_MINOR, UITokens.DOSSIER_INK, col_w,
			HORIZONTAL_ALIGNMENT_LEFT, String(buffs[i]))

static func _draw_max(panel, x: float, w: float) -> void:
	var current: Dictionary = panel._model.get("current", {})
	var side := 120.0
	var icon: Texture2D = panel._era_texture(String(current.get("id", "")))
	if icon != null:
		panel._canvas.draw_texture_rect(icon, Rect2(Vector2(x + (w - side) * 0.5, panel.BAND_CENTER - 44.0),
			Vector2.ONE * side), false)
	panel._draw_buffs(x, w, panel.COST_HEAD_Y - 40.0, "已获得的时代加成")
