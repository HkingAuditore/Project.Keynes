extends Control
class_name NationalProcurementSlider

## 国家购买预算：每日把国库现金的 0–10% 用于国家购买
## （派遣储备 + 时代晋升收购 + 科技值采购）。
##
## 与 ProcurementBudgetSlider 同一套卷宗绘制：自绘轨道、拖动即预览、松手才提交；
## 最左端即关闭。组件只发出意图，命令由宿主经 PlayerController 提交
## （`procurement.set_policy {treasury_share_bp, research_share_bp}`）。
## 数据来自 EconomyFacade.country_procurement_snapshot()；原生接口缺席时
## 按国库现金估算日额，分项与上一周期实付只在快照可用时出现。

signal policy_previewed(treasury_share_bp: int)
signal policy_committed(treasury_share_bp: int)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const COMMAND_SET_POLICY := &"procurement.set_policy"
const CASH_SCALE := 10000.0
const MAX_TREASURY_SHARE_BP := 1000
## 0.1% 一档：拖动分辨率与读数精度一致，提交值不会出现 0.137% 这类伪精度。
const STEP_BP := 10
const DEFAULT_TREASURY_SHARE_BP := 200
const DEFAULT_RESEARCH_SHARE_BP := 5000
const TRACK_TOP := 61.0
const TRACK_HEIGHT := 8.0
const MAX_TRACK_WIDTH := 680.0
const HIT_BAND := 13.0
const GRABBER_RADIUS := 6.5
const TICKS := [0.0, 0.25, 0.5, 0.75, 1.0]
const NOTE_TEXT := "国家购买包括派遣储备、升级时代与科技投入"
const LINE_FONT := 15
const VALUE_FONT := 18

var _treasury_share_bp := 0
var _research_share_bp := DEFAULT_RESEARCH_SHARE_BP
var _treasury := 0
var _procurement: Dictionary = {}
var _dragging := false
var _hovered := false
var _track_style := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	_track_style.set_corner_radius_all(int(TRACK_HEIGHT * 0.5))
	_track_style.anti_aliasing = true
	custom_minimum_size = Vector2(0.0, 146.0)
	mouse_filter = Control.MOUSE_FILTER_PASS
	tooltip_text = "每日从国库现金中拨出这一比例用于国家购买；拖到最左端即关闭，松手立即生效"


## treasury_share_bp：每日国库现金份额 0..1000（= 0–10%）；
## procurement：present_procurement() 规整后的快照，可为空。
func set_state(treasury_share_bp: int, research_share_bp: int, treasury_cash: int,
		procurement: Dictionary = {}) -> void:
	_treasury = maxi(0, treasury_cash)
	_research_share_bp = clampi(research_share_bp, 0, 10000)
	_procurement = procurement
	if not _dragging:
		_treasury_share_bp = clampi(treasury_share_bp, 0, MAX_TREASURY_SHARE_BP)
	queue_redraw()


func treasury_share_bp() -> int:
	return _treasury_share_bp


func research_share_bp() -> int:
	return _research_share_bp


func is_enabled() -> bool:
	return _treasury_share_bp > 0


func is_dragging() -> bool:
	return _dragging


## 当前份额下的每日国家购买额（MONEY_SCALE 现金）。快照份额与当前一致时用
## 运行时冻结的日额，否则（拖动中 / 刚提交未生效）按国库现金估算。
func national_daily_budget() -> int:
	if not is_enabled():
		return 0
	if _snapshot_matches():
		return maxi(0, int(_procurement.get("national_daily_budget", 0)))
	return int(round(float(_treasury) * float(_treasury_share_bp) / 10000.0))


## {research, era, colonization} 每日分配（MONEY_SCALE）。
func allocation() -> Dictionary:
	var national := national_daily_budget()
	if national <= 0:
		return {"research": 0, "era": 0, "colonization": 0}
	if _snapshot_matches():
		return {
			"research": maxi(0, int(_procurement.get("research_daily_budget", 0))),
			"era": maxi(0, int(_procurement.get("era_daily_budget", 0))),
			"colonization": maxi(0, int(_procurement.get("colonization_daily_budget", 0))),
		}
	var research := int(round(float(national) * float(_research_share_bp) / 10000.0))
	var other := national - research
	# 估算口径与 §2.2 一致：两项都有需求时对半；只有派遣时全给派遣。
	var era := 0
	if bool(_procurement.get("era_active", false)):
		var era_seen := int(_procurement.get("era_daily_budget", 0))
		var colonization_seen := int(_procurement.get("colonization_daily_budget", 0))
		var weight := 0.5
		if era_seen + colonization_seen > 0:
			weight = float(era_seen) / float(era_seen + colonization_seen)
		era = int(round(float(other) * weight))
	return {"research": research, "era": era, "colonization": other - era}


func value_text() -> String:
	if not is_enabled():
		return "已关闭"
	return "每日 %s" % _money(national_daily_budget())


func share_text() -> String:
	if not is_enabled():
		return "不拨付国家购买，派遣、时代晋升与科技采购均暂停"
	return "占国库 %s/日" % _percent_text(_treasury_share_bp)


func breakdown_text() -> String:
	if not is_enabled():
		return ""
	var parts := allocation()
	return "科技 %s · 时代晋升 %s · 派遣储备 %s" % [
		_money(int(parts.research)), _money(int(parts.era)), _money(int(parts.colonization))]


## 上一周期实际支出；原生快照不可用时返回空串（不显示）。
func last_epoch_text() -> String:
	if not bool(_procurement.get("available", false)):
		return ""
	var research := int(_procurement.get("research_cash_spent_last_epoch", 0))
	var era := int(_procurement.get("era_last_epoch_cash", 0))
	var colonization := int(_procurement.get("colonization_cash_spent_last_epoch", 0))
	return "上一周期实付 科技 %s · 时代晋升 %s · 派遣储备 %s" % [
		_money(research), _money(era), _money(colonization)]


func note_text() -> String:
	return NOTE_TEXT


func _snapshot_matches() -> bool:
	return bool(_procurement.get("available", false)) \
		and bool(_procurement.get("policy_enabled", false)) \
		and int(_procurement.get("treasury_share_bp", -1)) == _treasury_share_bp \
		and int(_procurement.get("research_share_bp", -1)) == _research_share_bp \
		and not _dragging


func _hit_band() -> float:
	return maxf(HIT_BAND, TouchUI.dense_units() * 0.5) if TouchUI.is_touch() else HIT_BAND


func _track_rect() -> Rect2:
	return Rect2(GRABBER_RADIUS, TRACK_TOP,
		maxf(1.0, minf(size.x, MAX_TRACK_WIDTH) - GRABBER_RADIUS * 2.0), TRACK_HEIGHT)


func _gui_input(event: InputEvent) -> void:
	var hit_band := _hit_band()
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if absf(button.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) > hit_band \
					or button.position.x > _track_rect().end.x + GRABBER_RADIUS + hit_band:
				return
			_dragging = true
			_apply_position(button.position.x)
			accept_event()
			return
		if _dragging:
			_dragging = false
			if TouchUI.is_touch():
				_hovered = false
			policy_committed.emit(_treasury_share_bp)
			queue_redraw()
			accept_event()
		elif TouchUI.is_touch() and _hovered:
			_hovered = false
			queue_redraw()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging:
			_apply_position(motion.position.x)
			accept_event()
			return
		var inside := absf(motion.position.y - (TRACK_TOP + TRACK_HEIGHT * 0.5)) <= hit_band \
			and motion.position.x <= _track_rect().end.x + GRABBER_RADIUS + hit_band
		if inside != _hovered:
			_hovered = inside
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hovered:
		_hovered = false
		queue_redraw()


func _apply_position(x: float) -> void:
	var track := _track_rect()
	var ratio := clampf((x - track.position.x) / track.size.x, 0.0, 1.0)
	var bp := int(round(ratio * float(MAX_TREASURY_SHARE_BP) / float(STEP_BP))) * STEP_BP
	_treasury_share_bp = clampi(bp, 0, MAX_TREASURY_SHARE_BP)
	queue_redraw()
	policy_previewed.emit(_treasury_share_bp)


func _grabber_x() -> float:
	var track := _track_rect()
	return track.position.x + track.size.x \
		* float(_treasury_share_bp) / float(MAX_TREASURY_SHARE_BP)


func _draw() -> void:
	var enabled := is_enabled()
	var strong := UITokens.dossier_font("sans_strong")
	var serif := UITokens.dossier_font("numeral")
	var track := _track_rect()
	var right := track.end.x + GRABBER_RADIUS
	IconCatalog.draw_icon(self, &"metric.treasury",
		Rect2(Vector2(2.0, 23.0 - 24.0 * 0.84), Vector2.ONE * 24.0), 1.0)
	draw_string(strong, Vector2(32.0, 22.0), "国家购买预算",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, UITokens.DOSSIER_INK)
	# 读数：左侧份额，右侧「每日 [金币] 数额」右对齐到轨道末端。
	_draw_runs(Vector2(1.0, 47.0), [share_text() if enabled else "最左端为关闭"],
		LINE_FONT, UITokens.DOSSIER_INK_MUTED, right * 0.55)
	var value_runs: Array = ["已关闭"] if not enabled \
		else ["每日 ", MoneyDisplay.MONEY, _amount(national_daily_budget())]
	var value_width := _runs_width(value_runs, VALUE_FONT, "numeral")
	_draw_runs(Vector2(right - value_width - 1.0, 47.0), value_runs, VALUE_FONT,
		UITokens.DOSSIER_OXBLOOD if enabled else UITokens.DOSSIER_INK_MUTED, -1.0, "numeral")
	_track_style.bg_color = UITokens.DOSSIER_TRACK
	draw_style_box(_track_style, track)
	for tick in TICKS:
		var tick_x := track.position.x + track.size.x * float(tick)
		draw_line(Vector2(tick_x, track.end.y + 2.0), Vector2(tick_x, track.end.y + 5.0),
			UITokens.DOSSIER_RULE, 1.0)
	if enabled:
		_track_style.bg_color = UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_OXBLOOD, 0.35)
		draw_style_box(_track_style, Rect2(track.position,
			Vector2(maxf(TRACK_HEIGHT, _grabber_x() - track.position.x), track.size.y)))
	var grabber := Vector2(_grabber_x(), TRACK_TOP + TRACK_HEIGHT * 0.5)
	var radius := GRABBER_RADIUS + (1.0 if _dragging or _hovered else 0.0)
	draw_circle(grabber, radius + 1.0, Color(UITokens.DOSSIER_INK, 0.35))
	draw_circle(grabber, radius, UITokens.DOSSIER_PAPER)
	draw_circle(grabber, radius - 2.5, UITokens.DOSSIER_OXBLOOD if enabled \
		else UITokens.DOSSIER_UMBER)
	var line_width := maxf(40.0, size.x - 2.0)
	var y := 94.0
	if enabled:
		var parts := allocation()
		_draw_runs(Vector2(1.0, y), [
			"科技 ", MoneyDisplay.MONEY, _amount(int(parts.research)),
			" · 时代晋升 ", MoneyDisplay.MONEY, _amount(int(parts.era)),
			" · 派遣储备 ", MoneyDisplay.MONEY, _amount(int(parts.colonization)),
		], LINE_FONT, UITokens.DOSSIER_INK_SOFT, line_width)
		y += 21.0
	if bool(_procurement.get("available", false)):
		_draw_runs(Vector2(1.0, y), [
			"上一周期实付 科技 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("research_cash_spent_last_epoch", 0))),
			" · 时代晋升 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("era_last_epoch_cash", 0))),
			" · 派遣储备 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("colonization_cash_spent_last_epoch", 0))),
		], 13, UITokens.DOSSIER_INK_MUTED, line_width)
		y += 19.0
	draw_string(UITokens.dossier_font("sans"), Vector2(1.0, maxf(y, 134.0)), NOTE_TEXT,
		HORIZONTAL_ALIGNMENT_LEFT, line_width, 13, UITokens.DOSSIER_INK_MUTED)


## 逐段绘制「文字 / 金币 / 数字」混排；金币用 MoneyDisplay，永远原色。
func _draw_runs(origin: Vector2, runs: Array, font_size: int, colour: Color,
		max_width: float = -1.0, font_kind: String = "sans") -> void:
	var font := UITokens.dossier_font(font_kind)
	var x := origin.x
	var limit := origin.x + max_width if max_width > 0.0 else INF
	for run in runs:
		if run is StringName and run == MoneyDisplay.MONEY:
			if x + MoneyDisplay.slot_width(font_size) > limit:
				return
			x += MoneyDisplay.draw_on_baseline(self, Vector2(x, origin.y), font_size, font)
			continue
		var text := String(run)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		draw_string(font, Vector2(x, origin.y), text, HORIZONTAL_ALIGNMENT_LEFT,
			maxf(1.0, limit - x) if limit < INF else -1.0, font_size, colour)
		x += width
		if x >= limit:
			return


func _runs_width(runs: Array, font_size: int, font_kind: String = "sans") -> float:
	var font := UITokens.dossier_font(font_kind)
	var width := 0.0
	for run in runs:
		if run is StringName and run == MoneyDisplay.MONEY:
			width += MoneyDisplay.slot_width(font_size)
		else:
			width += font.get_string_size(String(run), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				font_size).x
	return width


static func _amount(cash: int) -> String:
	return UITokens.format_compact_number_cn(float(cash) / CASH_SCALE, 2)


## 测试与文本读数用：数额前不写单位，渲染时由金币图标承担单位。
static func _money(cash: int) -> String:
	return _amount(cash)


static func _percent_text(bp: int) -> String:
	return "%.1f%%" % (float(bp) / 100.0)


# ---------------------------------------------------------------------------
# 政策解析与提交（经济国库页与科技页共用，宿主只持有 PlayerController）。
# ---------------------------------------------------------------------------

## 当前生效/待生效的国家购买政策。优先玩家会话（命令写入即更新），其次宿主
## 刚提交成功的本地值，再其次原生快照，最后是会话默认值（国库 2%/日、科技 50%）。
static func resolve_policy(controller, procurement: Dictionary,
		local_override: Dictionary = {}) -> Dictionary:
	if controller != null and controller.has_method("get_procurement_policy"):
		var policy = controller.get_procurement_policy()
		if policy is Dictionary and (policy as Dictionary).has("treasury_share_bp"):
			return {
				"treasury_share_bp": clampi(int(policy.get("treasury_share_bp", 0)),
					0, MAX_TREASURY_SHARE_BP),
				"research_share_bp": clampi(int(policy.get("research_share_bp",
					DEFAULT_RESEARCH_SHARE_BP)), 0, 10000),
				"source": "session",
			}
	if not local_override.is_empty():
		return {
			"treasury_share_bp": int(local_override.get("treasury_share_bp", 0)),
			"research_share_bp": int(local_override.get("research_share_bp",
				DEFAULT_RESEARCH_SHARE_BP)),
			"source": "local",
		}
	if bool(procurement.get("available", false)) \
			and bool(procurement.get("policy_enabled", false)):
		return {
			"treasury_share_bp": clampi(int(procurement.get("treasury_share_bp", 0)),
				0, MAX_TREASURY_SHARE_BP),
			"research_share_bp": clampi(int(procurement.get("research_share_bp",
				DEFAULT_RESEARCH_SHARE_BP)), 0, 10000),
			"source": "snapshot",
		}
	return {
		"treasury_share_bp": DEFAULT_TREASURY_SHARE_BP,
		"research_share_bp": DEFAULT_RESEARCH_SHARE_BP,
		"source": "default",
	}


## 经 PlayerController 提交国家购买政策；返回 request_command 的结果字典。
static func submit_policy(controller, treasury_share_bp: int,
		research_share_bp: int) -> Dictionary:
	if controller == null or not controller.has_method("request_command"):
		return {"ok": false, "code": "no_player_controller", "reason": "玩家会话尚未就绪"}
	return controller.request_command(COMMAND_SET_POLICY, {
		"treasury_share_bp": clampi(treasury_share_bp, 0, MAX_TREASURY_SHARE_BP),
		"research_share_bp": clampi(research_share_bp, 0, 10000),
	})


static func is_unsupported(result: Dictionary) -> bool:
	return String(result.get("code", result.get("reason", ""))) == "unsupported_command"
