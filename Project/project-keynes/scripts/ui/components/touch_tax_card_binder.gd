extends Control

## 触摸端税卡无表单化绑定器：在触摸档隐藏卡片内密集的 OptionButton/SpinBox，
## 将整张税卡变为清爽的大尺寸可读摘要按钮，点击即打开 TouchTaxSheet 侧滑抽屉集中编辑。
## 桌面档（is_touch() == false）全程零介入。

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const SHEET_SCENE_PATH := "res://scenes/ui/touch_tax_sheet.tscn"

const TOUCH_CARD_SIZE := Vector2(310.0, 72.0)
const DRAG_TOLERANCE := 14.0
const KIND_NAMES := {
	"income": "所得税",
	"consumption": "交易",
	"business": "营业税",
	"import": "进口",
	"export": "出口",
}

var _workspace_ref: WeakRef
var _card_key := ""
var _pressing := false
var _press_pos := Vector2.ZERO
var _press_touch_index := -1


static func bind_card(workspace: Control, key: String, card: Dictionary) -> void:
	if not TouchUI.is_touch() or workspace == null:
		return
	var panel := card.get("control") as PanelContainer
	if panel == null:
		return
	panel.custom_minimum_size = TOUCH_CARD_SIZE
	var lanes_box := panel.get_node_or_null("Body/Lanes") as Control
	if lanes_box != null:
		lanes_box.visible = false
	var sub := card.get("sub") as Label
	if sub != null:
		sub.visible = true
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var existing_hit := panel.get_node_or_null("TouchTaxCardHit") as Control
	if existing_hit != null:
		existing_hit._workspace_ref = weakref(workspace)
		existing_hit._card_key = key
		return
	var script := load("res://scripts/ui/components/touch_tax_card_binder.gd") as GDScript
	var hit := script.new() as Control
	hit.name = "TouchTaxCardHit"
	hit._workspace_ref = weakref(workspace)
	hit._card_key = key
	hit.mouse_filter = Control.MOUSE_FILTER_PASS
	hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(hit)


static func bind_group(controller: RefCounted, group_key: String, entry: Dictionary) -> void:
	if not TouchUI.is_touch() or controller == null:
		return
	var root := entry.get("control") as Control
	if root == null:
		return
	var lanes_box := root.get_node_or_null("Header/Row/Lanes") as Control
	var edit_btn := root.get_node_or_null("Header/Row/GroupTouchEdit") as Button
	if lanes_box == null or edit_btn == null:
		return
	lanes_box.visible = false
	edit_btn.visible = true
	var ctrl_weak: WeakRef = weakref(controller)
	edit_btn.pressed.connect(func() -> void:
		var target_ctrl: RefCounted = ctrl_weak.get_ref() as RefCounted
		if target_ctrl == null:
			return
		var groups: Dictionary = target_ctrl.get("_groups_by_key")
		if not groups.has(group_key):
			return
		var grp: Dictionary = groups[group_key]
		var kinds: Array = grp.get("kinds", [])
		var spins: Dictionary = grp.get("spins", {})
		var lanes: Array = []
		for kind in kinds:
			var spin := spins.get(kind) as SpinBox
			if spin == null:
				continue
			var cleaned: String = MoneyDisplay.strip_unit(spin.get_line_edit().text).replace("%", "").replace(" ", "").strip_edges()
			var captured_kind := String(kind)
			var mode := int(target_ctrl.call("_group_mode", group_key, captured_kind))
			lanes.append({
				"kind": captured_kind,
				"label": String(KIND_NAMES.get(captured_kind, captured_kind)),
				"value_text": cleaned if (cleaned.is_valid_int() or cleaned.is_valid_float()) else "0",
				"mode": mode,
				"hint": "将本组全部条目统一设为该税率",
				"can_reset": true,
				"commit": func(text: String, new_mode: int) -> void:
					var c: RefCounted = ctrl_weak.get_ref() as RefCounted
					if c != null:
						c.call("_on_group_rate_confirmed", text, group_key, captured_kind, new_mode),
				"reset": func() -> void:
					var c: RefCounted = ctrl_weak.get_ref() as RefCounted
					if c != null:
						c.call("_on_group_reset_pressed", group_key, captured_kind),
			})
		var sheet: Control = _ensure_sheet_for_node(edit_btn)
		if sheet != null:
			sheet.call("open_for_card", "%s（整组）" % String(grp.get("label", "分组")), lanes, 0))


func _exit_tree() -> void:
	_pressing = false
	_press_touch_index = -1


static func sync_card(_workspace: Control, card: Dictionary) -> void:
	if not TouchUI.is_touch():
		return
	var sub := card.get("sub") as Label
	if sub == null:
		return
	var kinds: Array = card.get("kinds", [])
	var spins: Dictionary = card.get("spins", {})
	var modes: Dictionary = card.get("assessment_modes", {})
	var overridden: Dictionary = card.get("overridden", {})
	var pendings: Dictionary = card.get("pendings", {})
	var is_default := bool(card.get("is_default", false))
	var parts := PackedStringArray()
	var any_override := is_default
	var any_pending := false
	for kind in kinds:
		var spin := spins.get(kind) as SpinBox
		if spin == null:
			continue
		var raw_text := MoneyDisplay.strip_unit(spin.get_line_edit().text).replace("%", "").strip_edges()
		var mode := int(modes.get(kind, 0))
		var shown := ("金币 %s" % raw_text) if mode == 1 else ("%s%%" % raw_text)
		var has_ovr := bool(overridden.get(kind, false))
		if has_ovr:
			any_override = true
		var p_ctl := pendings.get(kind) as Control
		if p_ctl != null and p_ctl.visible:
			any_pending = true
		if kinds.size() > 1:
			parts.append("%s %s%s" % [String(KIND_NAMES.get(kind, kind)), shown,
				"*" if has_ovr and not is_default else ""])
		else:
			parts.append(shown if (has_ovr or is_default) else ("默认 %s" % shown))
	var summary := "  ·  ".join(parts)
	if any_pending:
		summary += "（待生效）"
	sub.text = summary
	sub.visible = true
	sub.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if any_override else UITokens.DOSSIER_INK_SOFT)


func _gui_input(event: InputEvent) -> void:
	var ws: Control = _workspace_ref.get_ref() as Control if _workspace_ref != null else null
	if not TouchUI.is_touch() or ws == null or not is_instance_valid(ws):
		return
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var global_pos := get_global_transform_with_canvas() * mb.position
		if mb.pressed:
			# Android/Web 可能同时派发原始触摸和兼容鼠标事件，只保留原始触摸状态。
			if _press_touch_index >= 0:
				return
			_pressing = true
			_press_touch_index = -1
			_press_pos = global_pos
			accept_event()
			return
		if not _pressing or _press_touch_index >= 0:
			return
		_pressing = false
		if global_pos.distance_to(_press_pos) <= DRAG_TOLERANCE:
			_open_sheet(ws)
			accept_event()
		return
	var touch := event as InputEventScreenTouch
	if touch == null:
		return
	if touch.pressed:
		_pressing = true
		_press_touch_index = touch.index
		_press_pos = touch.position
		accept_event()
		return
	if not _pressing or _press_touch_index != touch.index:
		return
	_pressing = false
	_press_touch_index = -1
	if touch.position.distance_to(_press_pos) <= DRAG_TOLERANCE:
		_open_sheet(ws)
		accept_event()


func _open_sheet(ws: Control) -> void:
	var rows: Dictionary = ws.get("_rows")
	if not rows.has(_card_key):
		return
	var card: Dictionary = rows[_card_key]
	var title_label := card.get("name") as Label
	var title_text: String = title_label.text if title_label != null else "调整税率"
	var is_default := bool(card.get("is_default", false))
	var kinds: Array = card.get("kinds", [])
	var spins: Dictionary = card.get("spins", {})
	var modes: Dictionary = card.get("assessment_modes", {})
	var overridden: Dictionary = card.get("overridden", {})
	var ws_weak: WeakRef = weakref(ws)
	var card_key_copy: String = _card_key
	var lanes: Array = []
	for kind in kinds:
		var spin := spins.get(kind) as SpinBox
		if spin == null:
			continue
		var cleaned: String = MoneyDisplay.strip_unit(spin.get_line_edit().text).replace("%", "").replace(" ", "").strip_edges()
		var mode := int(modes.get(kind, 0))
		var def_rate := int(ws.call("_default_rate", kind))
		var def_mode := int(ws.call("_default_mode", kind))
		var hint: String = "" if is_default else ("国家默认 %s" % TaxLaneEditor._format_value(def_rate, def_mode))
		var captured_kind := String(kind)
		lanes.append({
			"kind": captured_kind,
			"label": String(KIND_NAMES.get(captured_kind, captured_kind)),
			"value_text": cleaned if not cleaned.is_empty() else "0",
			"mode": mode,
			"hint": hint,
			"can_reset": not is_default and bool(overridden.get(captured_kind, false)),
			"commit": func(text: String, new_mode: int) -> void:
				var target_ws: Control = ws_weak.get_ref() as Control
				if target_ws != null and is_instance_valid(target_ws):
					target_ws.call("_on_rate_confirmed", text, card_key_copy, captured_kind, new_mode),
			"reset": func() -> void:
				var target_ws: Control = ws_weak.get_ref() as Control
				if target_ws != null and is_instance_valid(target_ws):
					target_ws.call("_on_reset_pressed", card_key_copy, captured_kind),
		})
	var sheet: Control = _ensure_sheet()
	if sheet != null:
		sheet.call("open_for_card", title_text, lanes, 0)


func _ensure_sheet() -> Control:
	return _ensure_sheet_for_node(self)


static func _ensure_sheet_for_node(origin: Node) -> Control:
	var layer: Node = origin
	while layer != null and not (layer is CanvasLayer):
		layer = layer.get_parent()
	if layer == null and origin != null and origin.is_inside_tree():
		layer = origin.get_tree().root
	if layer == null:
		return null
	var existing := layer.get_node_or_null("TouchTaxSheet") as Control
	if existing != null:
		return existing
	var scene := load(SHEET_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate() as Control
	inst.name = "TouchTaxSheet"
	layer.add_child(inst)
	return inst
