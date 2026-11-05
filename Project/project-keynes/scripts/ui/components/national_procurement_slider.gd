extends "res://scripts/ui/components/budget_share_slider.gd"
class_name NationalProcurementSlider

## 国家购买预算：每日把国库现金的 0–10% 用于国家购买
## （科技采购 + 时代晋升收购 + 派遣储备）。
##
## 交互与绘制骨架来自 BudgetShareSlider（拖动即预览、松手才提交、最左端关闭、
## 键盘/手柄逐档），这里只负责「这一份额折算成多少钱」的读数与卷宗版式。
## 组件只发出意图，命令由宿主经 PlayerController 提交
## （`procurement.set_policy {treasury_share_bp, research_share_bp}`）。
## 数据来自 EconomyFacade.country_procurement_snapshot()；原生接口缺席时
## 按国库现金估算日额，分项与上一周期实付只在快照可用时出现。

signal policy_previewed(treasury_share_bp: int)
signal policy_committed(treasury_share_bp: int)

const COMMAND_SET_POLICY := &"procurement.set_policy"
const CASH_SCALE := 10000.0
const MAX_TREASURY_SHARE_BP := 1000
## 0.1% 一档：拖动分辨率与读数精度一致，提交值不会出现 0.137% 这类伪精度。
const STEP_BP := 10
const DEFAULT_TREASURY_SHARE_BP := 200
const DEFAULT_RESEARCH_SHARE_BP := 5000
const TRACK_TOP := 61.0
const SLIDER_HEIGHT := 146.0
const CONDENSED_HEIGHT := 56.0
const CONDENSED_TRACK_TOP := 30.0
const NOTE_TEXT := "国家购买包括派遣储备、升级时代与科技投入"
const FOOT_TOP := 94.0

var _treasury_share_bp := 0
var _research_share_bp := DEFAULT_RESEARCH_SHARE_BP
var _treasury := 0
var _procurement: Dictionary = {}


func _init() -> void:
	configure_layout(SLIDER_HEIGHT, TRACK_TOP, CONDENSED_HEIGHT, CONDENSED_TRACK_TOP)
	configure("国家购买预算", &"metric.treasury", MAX_TREASURY_SHARE_BP, STEP_BP, NOTE_TEXT)
	# 基类发的是份额级信号；对外仍用政策语义的旧名字，宿主与测试无需改动。
	# 在 _init 里连，节点尚未入树时也能立刻收到预览，不依赖 _ready 的时序。
	share_previewed.connect(_relay_preview)
	share_committed.connect(_relay_commit)


func _ready() -> void:
	super()
	tooltip_text = "每日从国库现金中拨出这一比例用于国家购买；拖到最左端即关闭，松手立即生效"


func _relay_preview(bp: int) -> void:
	policy_previewed.emit(bp)


func _relay_commit(bp: int) -> void:
	policy_committed.emit(bp)


## treasury_share_bp：每日国库现金份额 0..1000（= 0–10%）；
## procurement：present_procurement() 规整后的快照，可为空。
## interactive=false 时整块降透明并忽略输入，但读数与说明仍可读（配合 tooltip 解释）。
func set_state(treasury_share_bp: int, research_share_bp: int, treasury_cash: int,
		procurement: Dictionary = {}, interactive := true) -> void:
	_treasury = maxi(0, treasury_cash)
	_research_share_bp = clampi(research_share_bp, 0, 10000)
	_procurement = procurement
	if not _dragging:
		_treasury_share_bp = clampi(treasury_share_bp, 0, MAX_TREASURY_SHARE_BP)
	set_share_state(_treasury_share_bp, interactive, "", "")


func treasury_share_bp() -> int:
	return _treasury_share_bp


func research_share_bp() -> int:
	return _research_share_bp


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
	# 估算口径与原生一致：两项都有需求时按既有权重；只有派遣时全给派遣。
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
		return "不拨付国家购买，科技、时代晋升与派遣均暂停"
	return "占国库 %s/日" % _percent_text(_treasury_share_bp)


func breakdown_text() -> String:
	if not is_enabled():
		return ""
	var parts := allocation()
	return "科技 %s · 时代晋升 %s · 派遣储备 %s" % [
		_money(int(parts.research)), _money(int(parts.era)), _money(int(parts.colonization))]


## 采购明细缺席时的说明；可用时返回空串。
func unavailable_text() -> String:
	if bool(_procurement.get("available", false)):
		return ""
	return "采购明细尚未汇总，当前按国库现金估算每日额度。"


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


## 份额变化的钩子：拖动时读数要跟手，所以每次改动都重算一次文本。
func _on_share_changed(_dragging_share: bool) -> void:
	_treasury_share_bp = _bp


func _snapshot_matches() -> bool:
	return bool(_procurement.get("available", false)) \
		and bool(_procurement.get("policy_enabled", false)) \
		and int(_procurement.get("treasury_share_bp", -1)) == _treasury_share_bp \
		and int(_procurement.get("research_share_bp", -1)) == _research_share_bp \
		and not _dragging


# ---------------------------------------------------------------------------
# 卷宗版式：标题、份额/日额双读数、分项与实付脚注。
# ---------------------------------------------------------------------------

func _draw_head(alpha: float, _track_top_value: float) -> void:
	if _condensed:
		return
	IconCatalog.draw_icon(self, &"metric.treasury",
		Rect2(Vector2(2.0, 23.0 - 24.0 * 0.84), Vector2.ONE * 24.0), alpha)
	draw_string(UITokens.dossier_font("sans_strong"), Vector2(32.0, 22.0), "国家购买预算",
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, Color(UITokens.DOSSIER_INK, alpha))


func _draw_readouts(alpha: float, track_top_value: float, right: float) -> void:
	var enabled := is_enabled()
	var baseline := (track_top_value - 9.0) if _condensed else 47.0
	var hint := share_text() if enabled else "最左端为关闭"
	draw_string(UITokens.dossier_font("sans"), Vector2(1.0, baseline), hint,
		HORIZONTAL_ALIGNMENT_LEFT, maxf(48.0, right * 0.55), LINE_FONT,
		Color(UITokens.DOSSIER_INK_MUTED, alpha))
	var runs: Array = ["已关闭"] if not enabled \
		else ["每日 ", MoneyDisplay.MONEY, _amount(national_daily_budget())]
	var width := _runs_width(runs, VALUE_FONT, "numeral")
	var colour := UITokens.DOSSIER_OXBLOOD if enabled else UITokens.DOSSIER_INK_MUTED
	_draw_runs(Vector2(maxf(1.0, right - width - 1.0), baseline), runs, VALUE_FONT,
		Color(colour, alpha), -1.0, "numeral")


func _draw_foot(alpha: float, _track_top_value: float, right: float) -> void:
	if _condensed:
		return
	var width := maxf(40.0, right)
	var y := FOOT_TOP
	if is_enabled():
		var parts := allocation()
		_draw_runs(Vector2(1.0, y), [
			"科技 ", MoneyDisplay.MONEY, _amount(int(parts.research)),
			" · 时代晋升 ", MoneyDisplay.MONEY, _amount(int(parts.era)),
			" · 派遣储备 ", MoneyDisplay.MONEY, _amount(int(parts.colonization)),
		], LINE_FONT, Color(UITokens.DOSSIER_INK_SOFT, alpha), width)
		y += 21.0
	var spent := last_epoch_text()
	if not spent.is_empty():
		_draw_runs(Vector2(1.0, y), [
			"上一周期实付 科技 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("research_cash_spent_last_epoch", 0))),
			" · 时代晋升 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("era_last_epoch_cash", 0))),
			" · 派遣储备 ", MoneyDisplay.MONEY,
			_amount(int(_procurement.get("colonization_cash_spent_last_epoch", 0))),
		], 13, Color(UITokens.DOSSIER_INK_MUTED, alpha), width)
		y += 19.0
	var placeholder := unavailable_text()
	if not placeholder.is_empty():
		draw_string(UITokens.dossier_font("sans"), Vector2(1.0, y), placeholder,
			HORIZONTAL_ALIGNMENT_LEFT, width, 13, Color(UITokens.DOSSIER_INK_MUTED, alpha))
		y += 19.0
	draw_string(UITokens.dossier_font("sans"), Vector2(1.0, maxf(y, 134.0)), NOTE_TEXT,
		HORIZONTAL_ALIGNMENT_LEFT, width, 13, Color(UITokens.DOSSIER_INK_MUTED, alpha))


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
# 政策解析与提交（经济国库页、财政页与科技页共用，宿主只持有 PlayerController）。
# ---------------------------------------------------------------------------

## 当前生效/待生效的国家购买政策。优先玩家会话（命令写入即更新），其次宿主
## 刚提交成功的本地值，再其次原生快照，最后是会话默认值（国库 2%/日、科技 50%）。
## era_share_bp / colonization_share_bp 为 -1 表示「沿用原生日额分配」。
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
				"era_share_bp": int((policy as Dictionary).get("era_share_bp", -1)),
				"colonization_share_bp": int(
					(policy as Dictionary).get("colonization_share_bp", -1)),
				"source": "session",
			}
	if not local_override.is_empty():
		return {
			"treasury_share_bp": int(local_override.get("treasury_share_bp", 0)),
			"research_share_bp": int(local_override.get("research_share_bp",
				DEFAULT_RESEARCH_SHARE_BP)),
			"era_share_bp": int(local_override.get("era_share_bp", -1)),
			"colonization_share_bp": int(local_override.get("colonization_share_bp", -1)),
			"source": "local",
		}
	if bool(procurement.get("available", false)) \
			and bool(procurement.get("policy_enabled", false)):
		return {
			"treasury_share_bp": clampi(int(procurement.get("treasury_share_bp", 0)),
				0, MAX_TREASURY_SHARE_BP),
			"research_share_bp": clampi(int(procurement.get("research_share_bp",
				DEFAULT_RESEARCH_SHARE_BP)), 0, 10000),
			"era_share_bp": int(procurement.get("era_share_bp", -1)),
			"colonization_share_bp": int(procurement.get("colonization_share_bp", -1)),
			"source": "snapshot",
		}
	return {
		"treasury_share_bp": DEFAULT_TREASURY_SHARE_BP,
		"research_share_bp": DEFAULT_RESEARCH_SHARE_BP,
		"era_share_bp": -1,
		"colonization_share_bp": -1,
		"source": "default",
	}


## 经 PlayerController 提交国家购买政策；返回 request_command 的结果字典。
## era/colonization 传负数表示本次不改（不写入命令，避免伪精度与误覆盖）。
static func submit_policy(controller, treasury_share_bp: int,
		research_share_bp: int, era_share_bp: int = -1,
		colonization_share_bp: int = -1) -> Dictionary:
	if controller == null or not controller.has_method("request_command"):
		return {"ok": false, "code": "no_player_controller", "reason": "玩家会话尚未就绪"}
	var args := {
		"treasury_share_bp": clampi(treasury_share_bp, 0, MAX_TREASURY_SHARE_BP),
		"research_share_bp": clampi(research_share_bp, 0, 10000),
	}
	if era_share_bp >= 0:
		args["era_share_bp"] = clampi(era_share_bp, 0, 10000)
	if colonization_share_bp >= 0:
		args["colonization_share_bp"] = clampi(colonization_share_bp, 0, 10000)
	return controller.request_command(COMMAND_SET_POLICY, args)


static func is_unsupported(result: Dictionary) -> bool:
	return String(result.get("code", result.get("reason", ""))) == "unsupported_command"
