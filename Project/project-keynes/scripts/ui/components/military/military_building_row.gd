extends DossierChart

## 一行官营建筑：剪纸建筑贴图 + 名称（×座数）+ 效果 + 建材成本 + 右侧纸片键。
##
## 动作完全由视图模型判定（`primary_action` / `can_demolish`），这里只负责画和把
## 点击抛回台账。两条通道必须物理分开：
##   - 主键 `_primary`：语义恒定，只可能是「建造 / 升级 / 再建」，到顶档不会变成拆除。
##   - 次级键 `_demolish`：默认不显形，悬停或获得焦点才出现，按下先进待确认态，
##     第二次按下才真的发拆除命令。
## 这样「右下角那个键」永远代表在这一格里增加建筑，破坏性操作不会和它共用落点。
##
## 文本三层：第一行建筑名 + 座数，第二行效果（青绿），第三行成本（黄铜色）或
## 缺料因由（胭脂）。回执临时占用效果行 3.5 秒，不新建节点。

signal action_pressed()
signal demolish_pressed()

const ROW_HEIGHT := 46.0
const ICON_SIZE := 24.0
const NAME_SIZE := 15
const EFFECT_SIZE := 12
const META_SIZE := 11
const COST_SIZE := 11
## 两个键共用同一套纸片尺寸：尺寸一致、只在墨色与层级上区分，才算同一套键体系。
const ACTION_WIDTH := 56.0
const ACTION_HEIGHT := 26.0
const DEMOLISH_WIDTH := 40.0
## 动作回执在效果行停留的秒数：够看清一句话，又不会把效果数字长期顶掉。
const NOTICE_SECONDS := 3.5
## 拆除待确认态存活时间：超时就自动取消，避免「我以为已经取消了」的误确认。
const CONFIRM_SECONDS := 3.0
## 建造成功后的纸片贴落动效时长（需求上限 260 ms）。
const STAMP_SECONDS := 0.24
## 数值变更的墨迹下划线淡出时长。
const INK_SECONDS := 0.4
## 提示卡正文：15px 与营造提示卡同级，版心 390px 让 424px 档案列也放得下。
const TOOLTIP_SIZE := 15
const TOOLTIP_WIDTH := 390.0

var _entry: Dictionary = {}
var _primary: Button
var _demolish: Button
var _busy := false
var _notice := ""
var _notice_oxblood := true
var _notice_until_msec := 0
## 拆除待确认态的截止时刻（0 = 不在待确认态）。
var _confirm_until_msec := 0
## 悬停/焦点：次级键只在「玩家已经指着这一行」时出现。
var _hovered := false
## 文本区可用宽度，由 `_sync_layout()` 统一算出：右侧要给两个键让位，
## 悬停时次级键从左边挤进来，不能让成本文字钻到键底下。
## 名字不能叫 `_text_width`：基类 `DossierChart` 已有同名测量方法。
var _text_room := 0.0
var _stamp := 1.0
var _stamp_tween: Tween
var _ink := 0.0
var _ink_tween: Tween
## 抖动位移（命令被拒时横摆两下），自绘与按钮一起偏移。
var _shake := 0.0
var _shake_tween: Tween
## 上一帧的座数与效果文本，用于判断「数值变了」该不该渗一次墨。
var _last_count := -1
var _last_effect := ""


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary = _make_chip(ACTION_WIDTH)
	_primary.pressed.connect(_on_primary_pressed)
	_demolish = _make_chip(DEMOLISH_WIDTH)
	_demolish.visible = false
	_demolish.pressed.connect(_on_demolish_pressed)
	set_process(false)


## 两个纸片键必须同形制：同一个 theme variation、同一套圆角与纸边，只换墨色。
## 用 `ChipButton` 而不是裸 `Button`：Godot 的提示只问**被悬停的那个控件**，
## 不会代问父节点。裸 Button 会拿自己的 `tooltip_text` 走默认 TooltipPanel——
## 那个面板不换行、超宽就被屏幕边缘裁掉，正好是玩家看不全建材的那一类 bug。
func _make_chip(width: float) -> Button:
	var chip := ChipButton.new()
	chip.theme_type_variation = &"PKDossierChip"
	chip.focus_mode = Control.FOCUS_ALL
	chip.custom_minimum_size = Vector2(width, ACTION_HEIGHT)
	chip.clip_text = true
	chip.tooltip_builder = Callable(get_script(), "build_tooltip_card")
	chip.mouse_entered.connect(_set_hovered.bind(true))
	chip.mouse_exited.connect(_set_hovered.bind(false))
	chip.focus_entered.connect(_on_focus_entered)
	chip.focus_exited.connect(_on_focus_exited)
	return chip


## 提示卡走纸片弹窗样式并显式开自动换行，而不是原生 `tooltip_text`。
## 原生 tooltip 只按最宽一行折、且不保证竖向空间：建材多到三五项时会被压成一条
## 横贯屏幕的长句，甚至被屏幕边缘裁掉。这座建筑吃多少料、每天维护多少，正是玩家
## 下单前必须看全的东西，不能赌渲染器的折行策略。
## 样式取主题里的 `PKPaperPopup`：别处的手绘纸片弹窗都用它，提示卡不该自成一格。
static func build_tooltip_card(text: String) -> Control:
	if text.strip_edges().is_empty():
		return null
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PKPaperPopup"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var copy := Label.new()
	copy.text = text
	copy.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	copy.add_theme_font_override("font", UITokens.dossier_font("sans"))
	copy.add_theme_font_size_override("font_size", TOOLTIP_SIZE)
	copy.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	# 版心宽度与营造提示卡一致（390px）：424px 的档案列也放得下，
	# `AUTOWRAP_WORD_SMART` 让长建材名在词边界折行，不会把一项拆成两段。
	copy.custom_minimum_size.x = TOOLTIP_WIDTH
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(copy)
	return panel


## 行本身的提示卡：指针落在图标、名字、成本段上都走这里。
func _make_custom_tooltip(for_text: String) -> Object:
	return build_tooltip_card(for_text)


## 纸片键专用按钮。必须由按钮自己覆写提示卡：悬停按钮时 Godot 只问按钮，
## 不会代问父行，裸 Button 于是退回不换行的默认 TooltipPanel。
class ChipButton extends Button:
	## 由建筑行注入的提示卡构建器（静态函数 Callable），避免内部类反查外部
	## `class_name`——这个脚本没有全局类名，`Xxx.build_tooltip_card` 取不到。
	var tooltip_builder: Callable

	func _make_custom_tooltip(for_text: String) -> Object:
		if tooltip_builder.is_valid():
			return tooltip_builder.call(for_text)
		return null


## 两个键的提示卡都由这一处刷新，保证它们指向同一份权威文本。
func _apply_tooltip(control: Control, text: String) -> void:
	if control == null:
		return
	var trimmed := text.strip_edges()
	control.tooltip_text = trimmed
	# 没有内容时彻底摘掉提示，避免空卡片从按钮边缘冒出来。
	control.mouse_default_cursor_shape = Control.CURSOR_ARROW if trimmed.is_empty() \
		else Control.CURSOR_POINTING_HAND


func _ready() -> void:
	add_child(_primary)
	add_child(_demolish)
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	resized.connect(_sync_layout)
	_sync_layout()


func set_data(entry: Dictionary) -> void:
	_entry = entry
	_busy = false
	# 新模型到达即取消待确认：对象可能已经变了，不能把旧确认套到新目标上。
	_cancel_confirm()
	_note_value_change()
	_sync_action()
	queue_redraw()


## 数值变化只做一次墨迹下划线，不整行重绘闪烁。
func _note_value_change() -> void:
	var count := int(_entry.get("count", 0))
	var effect := String(_entry.get("effect", ""))
	var changed := (_last_count >= 0 and count != _last_count) \
		or (not _last_effect.is_empty() and effect != _last_effect)
	_last_count = count
	_last_effect = effect
	if changed:
		_play_ink()


## 按下后先锁住，等下一次模型落地（set_data）再解锁，避免同日重复下单。
func set_busy(busy: bool) -> void:
	_busy = busy
	_sync_action()


## 命令回执：被拒的理由 / 已排队的确认，临时占用效果行（3.5 秒后回到效果数字）。
## 不新建节点：这一行本来就是自绘的，「节点数不变」契约与结构测试都靠这条。
func flash_notice(message: String, ok: bool) -> void:
	var text := message.strip_edges()
	if text.is_empty():
		return
	_notice = text
	_notice_oxblood = not ok
	_notice_until_msec = Time.get_ticks_msec() + int(NOTICE_SECONDS * 1000.0)
	# 被拒时配一次短促抖动：只变色太容易被忽略。
	if not ok:
		_play_shake()
	else:
		_play_stamp()
	set_process(true)
	queue_redraw()


func notice_text() -> String:
	return _notice


func entry() -> Dictionary:
	return _entry


## 主键（建造 / 升级 / 再建）。测试与台账都通过它触发正向动作。
func action_button() -> Button:
	return _primary


## 次级拆除键。默认不可见，只有悬停/焦点时显形。
func demolish_button() -> Button:
	return _demolish


func confirm_pending() -> bool:
	return _confirm_until_msec > 0


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _confirm_until_msec > 0 and now >= _confirm_until_msec:
		_cancel_confirm()
		_sync_action()
		queue_redraw()
	if _notice.is_empty():
		if _confirm_until_msec <= 0:
			set_process(false)
		return
	if now < _notice_until_msec:
		return
	_notice = ""
	_notice_oxblood = true
	if _confirm_until_msec <= 0:
		set_process(false)
	queue_redraw()


func _set_hovered(hovered: bool) -> void:
	if _hovered == hovered:
		return
	_hovered = hovered
	# 指针离开行就放弃待确认：需求要求「移开指针即取消」。
	if not hovered:
		_cancel_confirm()
	_sync_action()
	queue_redraw()


func _on_focus_entered() -> void:
	_hovered = true
	_sync_action()
	queue_redraw()


func _on_focus_exited() -> void:
	# 焦点移到同一行的另一个键时不收起，否则键盘用户会看到键在眼前消失。
	if _primary.has_focus() or _demolish.has_focus():
		return
	_hovered = false
	_sync_action()
	queue_redraw()


func _sync_layout() -> void:
	if _primary == null or _demolish == null:
		return
	# 4096 这种极小尺寸只出现在容器还没排版时：此时用宽度算位置会把键推到容器外，
	# 让溢出断言抓到假阳性。等真实尺寸落地后再排。
	var row_width := size.x
	if row_width <= 0.0:
		return
	_primary.size = Vector2(ACTION_WIDTH, ACTION_HEIGHT)
	_primary.position = Vector2(maxf(0.0, row_width - ACTION_WIDTH),
		(size.y - ACTION_HEIGHT) * 0.5)
	# 拆除键贴在主键左侧：破坏性操作永远是「次要的那一个」。
	_demolish.size = Vector2(DEMOLISH_WIDTH, ACTION_HEIGHT)
	_demolish.position = Vector2(
		maxf(0.0, row_width - ACTION_WIDTH - DEMOLISH_WIDTH - 4.0),
		(size.y - ACTION_HEIGHT) * 0.5)
	# 文本区始终扣掉两个键的位置（+ 8px 间隔）：次级键显形时文字不动、不被压住。
	var text_x := ICON_SIZE + 8.0
	_text_room = maxf(0.0,
		row_width - text_x - (ACTION_WIDTH + DEMOLISH_WIDTH + 4.0 + 8.0))
	queue_redraw()


## 文本区可用宽度（扣掉两个纸片键的占位）。424px 页宽下成本段仍有它的位置，
## 就说明成本与双键确实共存，而不是靠隐藏按钮换来的。
func text_room() -> float:
	return _text_room


func _sync_action() -> void:
	if _primary == null or _demolish == null:
		return
	var primary := String(_entry.get("primary_action", "none"))
	var blocked := not String(_entry.get("cost_reason", "")).is_empty()
	_primary.visible = primary != "none"
	_primary.disabled = _busy or blocked
	_primary.text = String(_entry.get("action_label", ""))
	# 整行与主键共用同一份提示卡文本：玩家指着建筑名、指着成本段、指着按钮，
	# 看到的都该是同一份完整清单（需求：提示卡必须列全建材与维护）。
	var tooltip := String(_entry.get("tooltip", ""))
	_apply_tooltip(self, tooltip)
	_apply_tooltip(_primary, tooltip)
	if _primary.visible:
		_primary.focus_mode = Control.FOCUS_ALL
	else:
		_primary.focus_mode = Control.FOCUS_NONE
	# 次级键：只在「有建筑可拆 + 玩家已经指着这一行 + 不在建」时出现。
	var demo_ok := bool(_entry.get("can_demolish", false)) \
		and not _busy and not blocked
	_demolish.visible = demo_ok and (_hovered or _confirm_until_msec > 0)
	_demolish.disabled = _busy
	_demolish.text = "确认拆除" if _confirm_until_msec > 0 else "拆除"
	_demolish.focus_mode = Control.FOCUS_ALL if _demolish.visible \
		else Control.FOCUS_NONE
	_apply_tooltip(_demolish,
		"拆掉这一行已建成的建筑，不退还建材。再按一次确认。"
		if _demolish.visible else "")
	if not demo_ok:
		_cancel_confirm()
	queue_redraw()


func _on_primary_pressed() -> void:
	if _busy:
		return
	# 主键永远只做正向的事：建造 / 升级 / 再建。
	action_pressed.emit()


func _on_demolish_pressed() -> void:
	if _busy:
		return
	if _confirm_until_msec <= 0:
		_confirm_until_msec = Time.get_ticks_msec() + int(CONFIRM_SECONDS * 1000.0)
		set_process(true)
		_sync_action()
		queue_redraw()
		return
	_cancel_confirm()
	demolish_pressed.emit()


func _cancel_confirm() -> void:
	_confirm_until_msec = 0


# ---------------------------------------------------------------- 动效
# 三种短动效统一走 Tween，减少动效偏好为真时全部跳过，只留文案与颜色变化。

func _play_stamp() -> void:
	if UIAnimation.reduced_motion():
		return
	_kill_tween(_stamp_tween)
	_stamp = 0.0
	_stamp_tween = create_tween()
	_stamp_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_stamp_tween.tween_method(_set_stamp, 0.0, 1.0, STAMP_SECONDS)


func _set_stamp(value: float) -> void:
	_stamp = value
	queue_redraw()


func _play_ink() -> void:
	if UIAnimation.reduced_motion():
		return
	_kill_tween(_ink_tween)
	_ink = 1.0
	_ink_tween = create_tween()
	_ink_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_ink_tween.tween_method(_set_ink, 1.0, 0.0, INK_SECONDS)


func _set_ink(value: float) -> void:
	_ink = value
	queue_redraw()


func _play_shake() -> void:
	if UIAnimation.reduced_motion():
		return
	_kill_tween(_shake_tween)
	_shake = 0.0
	_shake_tween = create_tween()
	_shake_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_shake_tween.tween_method(_set_shake, 1.0, 0.0, UITokens.ANIM_FAST)


func _set_shake(value: float) -> void:
	_shake = value
	queue_redraw()


func _kill_tween(tween: Tween) -> void:
	if tween != null and tween.is_valid():
		tween.kill()


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	if _entry.is_empty():
		return
	var w := size.x
	var shake_x := sin(_shake * PI * 4.0) * 3.0 * _shake
	var icon: StringName = StringName(_entry.get("icon", ""))
	# 贴落动效：整行从上方 3px 落定并轻微放大，收尾时正好回到原位。
	var stamp_y := (1.0 - _stamp) * -3.0
	var origin := Vector2(shake_x, stamp_y)
	if icon != &"":
		IconCatalog.draw_icon(self, icon, Rect2(
			origin + Vector2(0.0, (size.y - ICON_SIZE) * 0.5),
			Vector2(ICON_SIZE, ICON_SIZE)))
	var text_x := ICON_SIZE + 8.0 + shake_x
	# 文本区宽度只在 `_sync_layout()` 里算一次（已扣掉主键 + 次级键的占位）。
	# 这里若再自己推一遍，悬停时次级键显形就会压住成本文字。
	var text_width := _text_room if _text_room > 0.0 \
		else maxf(40.0, w - text_x - ACTION_WIDTH - 8.0)
	var name := String(_entry.get("name", ""))
	# 建筑名与部队番号用同一套无衬线粗体：显示字体的宋体在 15px 会缺字（戍/砌/馆 变方框）。
	var fitted := _fit_text(name, NAME_SIZE, text_width)
	_text(origin + Vector2(text_x, 20.0), fitted, NAME_SIZE, UITokens.DOSSIER_INK,
		"sans_strong")
	var count := int(_entry.get("count", 0))
	if count > 1:
		var name_width := _text_width(fitted, NAME_SIZE, "sans_strong")
		_text(origin + Vector2(text_x + name_width + 6.0, 19.0), "×%d" % count,
			META_SIZE, UITokens.DOSSIER_INK_MUTED, "sans_strong")
	# 待确认态必须在行内点明要拆的是哪一座：玩家不该在不确定对象的情况下按确认。
	if _confirm_until_msec > 0:
		var mark := _fit_text("将拆除 · %s" % name, COST_SIZE, text_width)
		_text(origin + Vector2(text_x, 35.0), mark, COST_SIZE,
			UITokens.DOSSIER_OXBLOOD, "sans_strong")
	else:
		_draw_status_line(origin, text_x, text_width)
	MilitaryPaperStyle.wobble_line(self, Vector2(0.0, size.y - 1.0),
		Vector2(w, size.y - 1.0), Color(UITokens.DOSSIER_RULE, 0.30), 1.0, 53, 0.4, 3)


## 第二行：回执优先，其次效果，最后成本。成本段用黄铜，缺料因由用胭脂。
## 右端另有一小段实物维护读数（满足率 / 可用天数 / 失修）：这条链路没接通时
## `maintenance_text` 是空串，整段不画，布局与旧版逐字一致。
func _draw_status_line(origin: Vector2, text_x: float, text_width: float) -> void:
	if not _notice.is_empty():
		_text(origin + Vector2(text_x, 36.0),
			_fit_text(_notice, EFFECT_SIZE, text_width), EFFECT_SIZE,
			UITokens.DOSSIER_OXBLOOD if _notice_oxblood
			else UITokens.DOSSIER_VERDIGRIS, "sans_strong")
		return
	var effect := String(_entry.get("effect", ""))
	var effect_width := 0.0
	if not effect.is_empty():
		var fitted := _fit_text(effect, EFFECT_SIZE, text_width)
		_text(origin + Vector2(text_x, 36.0), fitted, EFFECT_SIZE,
			UITokens.DOSSIER_VERDIGRIS, "sans_strong")
		effect_width = _text_width(fitted, EFFECT_SIZE, "sans_strong")
	var maintenance := _maintenance_line(text_width)
	var maintenance_width := 0.0
	if not maintenance.is_empty():
		maintenance_width = _text_width(maintenance, COST_SIZE, "sans_strong") + 8.0
	var cost_text := _cost_line()
	if cost_text.is_empty():
		_draw_maintenance(origin, text_x, text_width, maintenance, maintenance_width)
		_draw_value_ink(origin, text_x, effect_width)
		return
	var gap := 8.0 if effect_width > 0.0 else 0.0
	var cost_x := text_x + effect_width + gap
	var room := text_width - effect_width - gap - maintenance_width
	if room < 24.0:
		# 太窄就把效果行让给成本：成本是玩家下单前必须看到的，效果可以靠提示卡补。
		cost_x = text_x
		room = maxf(24.0, text_width - maintenance_width)
	var reason := String(_entry.get("cost_reason", ""))
	_text(origin + Vector2(cost_x, 36.0), _fit_text(cost_text, COST_SIZE, room),
		COST_SIZE, UITokens.DOSSIER_OXBLOOD if not reason.is_empty()
		else UITokens.DOSSIER_BRASS, "sans_strong")
	_draw_maintenance(origin, text_x, text_width, maintenance, maintenance_width)
	_draw_value_ink(origin, text_x, effect_width)


## 第二行右端的实物维护读数。空串 = 这条链路没接通（旧 DLL / 未建成），
## 直接不画；失修时整段换胭脂色。
func _maintenance_line(text_width: float) -> String:
	var text := String(_entry.get("maintenance_text", ""))
	if text.is_empty():
		return ""
	return _fit_text(text, COST_SIZE, maxf(0.0, text_width * 0.6))


func _draw_maintenance(origin: Vector2, text_x: float, text_width: float,
		text: String, width: float) -> void:
	if text.is_empty() or width <= 0.0:
		return
	var colour := UITokens.DOSSIER_OXBLOOD if bool(_entry.get("disrepair", false)) \
		else UITokens.DOSSIER_INK_MUTED
	_text(origin + Vector2(text_x + text_width - width + 8.0, 36.0), text,
		COST_SIZE, colour, "sans_strong")


## 成本总览：「建材 · 工期」，缺料/缺钱时改写成短因由（需求 1.1 / 1.5）。
func _cost_line() -> String:
	var reason := String(_entry.get("cost_reason", ""))
	if not reason.is_empty():
		return reason
	var materials := String(_entry.get("materials_text", ""))
	var days := String(_entry.get("cost_days_text", ""))
	if materials.is_empty():
		return days
	if days.is_empty():
		return materials
	return "%s · %s" % [materials, days]


## 数值刚变过时在它下面渗一道墨线，0.4 秒内淡出（需求 5.4）。
func _draw_value_ink(origin: Vector2, text_x: float, width: float) -> void:
	if _ink <= 0.01 or width <= 0.0:
		return
	MilitaryPaperStyle.wobble_line(self,
		origin + Vector2(text_x, 39.0),
		origin + Vector2(text_x + width, 39.0),
		Color(UITokens.DOSSIER_OXBLOOD, 0.55 * _ink), 1.4, 71, 0.5, 3)
