extends DossierChart
class_name DossierGdpBand

## 国民经济卷宗页头的「年度累计产值」横幅。
##
## 与 KPI 条同一套语汇（纸带底、黄铜竖标、衬线数字），但权重明显更高：
## 主数字 30px 衬线，右侧是年度进度而不是趋势线——产值是流量，累计值只涨不跌，
## 画曲线没有信息量，画"这一年已经走了多少"才有。
##
## 数据来自 EconomyGdpLedger，纯内存读取：横幅每日刷新不触发任何原生查询。

const HEIGHT := 82.0
const COMPACT_WIDTH := 430.0
const NARROW_WIDTH := 320.0
## 宽版面下主数字放大，否则 1500px 宽的纸带里 30px 数字读起来像正文。
const WIDE_WIDTH := 900.0
## 左侧黄铜竖标的宽度与上下留白，和 PKDossierAside 的竖线同语言。
const RULE_WIDTH := 2.0
const RULE_INSET := 14.0
## 竖标不贴纸带边框，否则会和 1px 边框糊成一条。
const RULE_X := 6.0
const PAD_LEFT := 18.0
const PAD_RIGHT := 16.0

var title := "本年度累计产值"
var _value := 0.0
var _from_value := 0.0
var _per_capita := NAN
var _per_day := 0.0
var _days_counted := 0
var _days_per_year := 365
var _year_index := 0
var _has_data := false
var _backfilled := false
var _partial := false
var _reason := ""


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## data 来自 EconomyDossierViewModel.gdp_headline()；金额已是货币单位（按 MONEY_SCALE 折算）。
func set_headline(data: Dictionary) -> void:
	var ok := bool(data.get("ok", false))
	_has_data = ok
	title = String(data.get("title", "本年度累计产值"))
	_reason = String(data.get("reason", ""))
	_from_value = _displayed_value()
	_value = float(data.get("value", 0.0)) if ok else 0.0
	if is_nan(_from_value) or is_nan(_value):
		_from_value = _value
	_per_capita = float(data.get("per_capita", NAN))
	_per_day = float(data.get("per_day", 0.0))
	_days_counted = int(data.get("days_counted", 0))
	_days_per_year = maxi(1, int(data.get("days_per_year", 365)))
	_year_index = int(data.get("year_index", 0))
	_backfilled = bool(data.get("backfilled", false))
	_partial = bool(data.get("partial", false))
	tooltip_text = _tooltip()
	_start_animation()


func value_text() -> String:
	return _money(_displayed_value())


func _displayed_value() -> float:
	if not _has_grown:
		return _value
	return lerpf(_from_value, _value, _blend)


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 1.0:
		return
	var compact := w < COMPACT_WIDTH
	var show_progress := w >= NARROW_WIDTH

	# 左侧黄铜竖标：把这一条标成"标题带"，与正文的墨色横线区分开。
	# 用 draw_rect 而不是圆角条形——2px 宽的细线在 1px 圆角下会被抗锯齿吃掉。
	draw_rect(Rect2(Vector2(RULE_X, RULE_INSET),
		Vector2(RULE_WIDTH, maxf(0.0, h - RULE_INSET * 2.0))),
		UITokens.DOSSIER_BRASS, true)

	var progress_width := clampf(w * 0.18, 72.0, 132.0) if show_progress else 0.0
	var right_reserve := progress_width + 26.0 if show_progress else 0.0
	var text_width := maxf(48.0, w - PAD_LEFT - PAD_RIGHT - right_reserve)

	# 小标
	_text(Vector2(PAD_LEFT, 19.0), _fit_text(title, 11, text_width, "sans_strong"),
		11, UITokens.DOSSIER_OXBLOOD, "sans_strong")

	# 主数字
	var value_size := 26
	if w >= WIDE_WIDTH:
		value_size = 34
	elif not compact:
		value_size = 30
	var shown := _money(_displayed_value())
	# 宽度按「金币 + 数字」整段量：图标也是主数字的一部分，不能只算字宽。
	if _money_width(shown, value_size, "serif") > text_width:
		value_size = 22
	_money_text(Vector2(PAD_LEFT, h - 28.0),
		_fit_text(shown, value_size, text_width - MoneyDisplay.slot_width(value_size), "serif"),
		value_size, _value_color(), "serif")

	# 人均 / 日均：整句混排，金额处插金币，读起来和主数字同单位。
	var detail := _detail_runs()
	if not detail.is_empty():
		if _mixed_width(detail, 12) > text_width:
			# 窄版面放不下图标时退回纯数字，宁可少一枚金币也不裁字。
			_text(Vector2(PAD_LEFT, h - 9.0), _fit_text(_detail_text(), 12, text_width),
				12, UITokens.DOSSIER_INK_SOFT)
		else:
			_mixed_line(Vector2(PAD_LEFT, h - 9.0), detail, 12, UITokens.DOSSIER_INK_SOFT)

	if show_progress:
		_draw_progress(w, h, progress_width)


func _draw_progress(w: float, h: float, progress_width: float) -> void:
	var x := w - PAD_RIGHT - progress_width
	var ratio := clampf(float(_days_counted) / float(_days_per_year), 0.0, 1.0)
	# 右块三件套整体垂直居中，与左侧小标/数字/副行的视觉重心对齐。
	var label := "年度进度 %d%%" % int(round(ratio * 100.0))
	_text(Vector2(x, h * 0.44), _fit_text(label, 11, progress_width),
		11, UITokens.DOSSIER_INK_MUTED)
	var track := Rect2(Vector2(x, h * 0.53), Vector2(progress_width, 3.0))
	draw_rect(track, Color(UITokens.DOSSIER_RULE, 0.55), true)
	if ratio > 0.0:
		draw_rect(Rect2(track.position, Vector2(progress_width * ratio, 3.0)),
			UITokens.DOSSIER_BRASS, true)
	var caption := "尚无结算日" if not _has_data \
		else "第 %d / %d 天" % [_days_counted, _days_per_year]
	_text(Vector2(x, h * 0.76), _fit_text(caption, 11, progress_width),
		11, UITokens.DOSSIER_INK_MUTED)

	# 与左侧数字区之间的细分隔线，沿用 KPI 条的竖线语言。
	var divider_x := x - 13.0
	draw_line(Vector2(divider_x, RULE_INSET), Vector2(divider_x, h - RULE_INSET),
		UITokens.DOSSIER_RULE, 1.0)


## 副行混排：文字段与金币标记交替，_mixed_line() 按顺序摆。
func _detail_runs() -> Array:
	if not _has_data:
		return [_reason if not _reason.is_empty() else "当日结算尚未提交"]
	var runs: Array = []
	if not is_nan(_per_capita):
		# 写「人均累计」而不是「人均」：页面下方还有「人均 GDP / 日」，
		# 两个数差十几倍，口径必须在词上就分开。
		runs.append_array(["人均累计 ", MoneyDisplay.MONEY, _money(_per_capita)])
	if _days_counted > 0:
		if not runs.is_empty():
			runs.append(" · ")
		runs.append_array(["日均 ", MoneyDisplay.MONEY, _money(_value / float(_days_counted))])
	if _days_counted <= 0:
		if not runs.is_empty():
			runs.append(" · ")
		runs.append("第 %d 天" % _days_counted)
	return runs


## 副行的纯文字版本：tooltip 与窄版面的退路，金额只剩数字。
func _detail_text() -> String:
	var parts := PackedStringArray()
	for run in _detail_runs():
		if typeof(run) != TYPE_STRING_NAME:
			parts.append(String(run))
	return "".join(parts)


func _value_color() -> Color:
	return UITokens.DOSSIER_OXBLOOD if _value < 0.0 else UITokens.DOSSIER_INK


## 金额只出数字：单位由绘制时画在数字左边的金币图标承担（见 MoneyDisplay）。
static func _money(value: float) -> String:
	if is_nan(value):
		return "—"
	return UITokens.format_compact_number_cn(value, 2)


func _tooltip() -> String:
	var lines := PackedStringArray()
	if not _has_data:
		lines.append(_reason if not _reason.is_empty() else "年度产值暂不可用")
		lines.append("等经济结算提交后这里会显示本年度累计产值。")
		return "\n".join(lines)
	lines.append("%s：%s" % [title, _money(_value)])
	if not is_nan(_per_capita):
		lines.append("人均产值：%s" % _money(_per_capita))
	if _days_counted > 0:
		lines.append("日均产值：%s" % _money(_value / float(_days_counted)))
	lines.append("口径：收入法 —— 建筑营收 − 中间投入 − 维护（= 工资 + 营业盈余，不含营业税）。")
	lines.append("逐格累加，各聚落之和即全国值。")
	var start_day := _year_index * _days_per_year
	lines.append("第 %d 年起算于第 %d 日，当前第 %d / %d 天。" % [
		_year_index + 1, start_day, _days_counted, _days_per_year])
	if _backfilled:
		lines.append("年初至首次结算的那几天按当时速率折算，之后逐日累计。")
	if _partial:
		lines.append("聚落过多，逐格累计未覆盖全部村落；全国值取自原生汇总。")
	return "\n".join(lines)
