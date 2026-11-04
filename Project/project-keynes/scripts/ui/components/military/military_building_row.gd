extends DossierChart

## 一行官营建筑：剪纸建筑贴图 + 名称（×座数）+ 效果，右侧一个动作纸片键。
## 动作由视图模型判定（build / upgrade / demolish / building / locked / unavailable），
## 这里只负责画和把点击抛回台账；按钮是真实 Button（三态 + 命中区），不是自绘热区。

signal action_pressed()

const ROW_HEIGHT := 46.0
const ICON_SIZE := 24.0
const NAME_SIZE := 15
const EFFECT_SIZE := 12
const META_SIZE := 11
const ACTION_WIDTH := 56.0
const ACTION_HEIGHT := 26.0

var _entry: Dictionary = {}
var _action: Button
var _busy := false


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action = Button.new()
	_action.theme_type_variation = &"PKDossierChip"
	_action.focus_mode = Control.FOCUS_NONE
	_action.custom_minimum_size = Vector2(ACTION_WIDTH, ACTION_HEIGHT)
	_action.clip_text = true


func _ready() -> void:
	add_child(_action)
	_action.pressed.connect(func() -> void:
		if _busy:
			return
		action_pressed.emit())
	resized.connect(_sync_layout)
	_sync_layout()


func set_data(entry: Dictionary) -> void:
	_entry = entry
	_busy = false
	_sync_action()
	queue_redraw()


## 按下后先锁住，等下一次模型落地（set_data）再解锁，避免同日重复下单。
func set_busy(busy: bool) -> void:
	_busy = busy
	_sync_action()


func entry() -> Dictionary:
	return _entry


func action_button() -> Button:
	return _action


func _sync_layout() -> void:
	if _action == null:
		return
	_action.size = Vector2(ACTION_WIDTH, ACTION_HEIGHT)
	_action.position = Vector2(maxf(0.0, size.x - ACTION_WIDTH),
		(size.y - ACTION_HEIGHT) * 0.5)
	queue_redraw()


func _sync_action() -> void:
	if _action == null:
		return
	var mode := String(_entry.get("action", "unavailable"))
	var executable := mode in ["build", "upgrade", "demolish"]
	_action.visible = executable
	_action.disabled = _busy
	_action.text = String(_entry.get("action_label", ""))
	_action.tooltip_text = String(_entry.get("tooltip", ""))
	queue_redraw()


func _draw() -> void:
	if _entry.is_empty():
		return
	var w := size.x
	var icon: StringName = StringName(_entry.get("icon", ""))
	if icon != &"":
		IconCatalog.draw_icon(self, icon, Rect2(Vector2(0.0, (size.y - ICON_SIZE) * 0.5),
			Vector2(ICON_SIZE, ICON_SIZE)))
	var text_x := ICON_SIZE + 8.0
	var text_width := maxf(40.0, w - text_x - ACTION_WIDTH - 8.0)
	var name := String(_entry.get("name", ""))
	# 建筑名与部队番号用同一套无衬线粗体：显示字体的宋体在 15px 会缺字（戍/砌/馆 变方框）。
	var fitted := _fit_text(name, NAME_SIZE, text_width)
	_text(Vector2(text_x, 20.0), fitted, NAME_SIZE, UITokens.DOSSIER_INK, "sans_strong")
	var count := int(_entry.get("count", 0))
	if count > 1:
		var name_width := _text_width(fitted, NAME_SIZE, "sans_strong")
		_text(Vector2(text_x + name_width + 6.0, 19.0), "×%d" % count, META_SIZE,
			UITokens.DOSSIER_INK_MUTED, "sans_strong")
	var effect := String(_entry.get("effect", ""))
	if not effect.is_empty():
		_text(Vector2(text_x, 36.0), _fit_text(effect, EFFECT_SIZE, text_width),
			EFFECT_SIZE, UITokens.DOSSIER_VERDIGRIS, "sans_strong")
	var mode := String(_entry.get("action", "unavailable"))
	if mode == "building":
		var days := int(_entry.get("pending_days", 0))
		var label := "在建 %d 日" % days if days > 0 else "在建"
		_text(Vector2(w - ACTION_WIDTH - 4.0, 20.0), label, META_SIZE,
			UITokens.DOSSIER_BRASS, "sans_strong", HORIZONTAL_ALIGNMENT_RIGHT,
			ACTION_WIDTH)
	elif mode == "locked":
		IconCatalog.draw_icon(self, &"technology.state.locked",
			Rect2(Vector2(w - 24.0, (size.y - 18.0) * 0.5), Vector2(18.0, 18.0)), 0.85)
	MilitaryPaperStyle.wobble_line(self, Vector2(text_x, size.y - 1.0),
		Vector2(w, size.y - 1.0), Color(UITokens.DOSSIER_RULE, 0.30), 1.0, 53, 0.4, 3)
