extends SceneTree

## 顶栏日历块（日期 + 时代）排印回归。
##
## 历史缺陷：DateLabel 在 .tscn 里被钉死 custom_minimum_size.x = 108，而
## "第1年 · 1月1日" 实测 117px，于是玩家看到的是"第1年 · 1月…"，时代名再把
## 剩下的空间挤掉。这里守住的硬契约是：
##   1) 字一定在纸框内：日期与时代的实测字宽都 <= 各自 Label 的宽度；
##   2) 纸框边缘留有余量：图标离纸框左边、时代文字离纸框右边都不少于
##      DateRow 在 .tscn 里声明的 offset（16px）；
##   3) 同一年内逐日推进不能让纸框宽度抖动（宽度取"数字全部换成 8"的上界）；
##   4) 窄窗优先整体降字号，降到地板仍放不下就让纸框变宽，绝不再裁字。
## 断言全部基于字体度量，headless 可跑。

const BAR_SCENE := "res://scenes/ui/player_top_bar.tscn"
const THEME_PATH := "res://assets/themes/player_session_theme.tres"
const DIMENSIONS: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1600, 960), Vector2i(1920, 1080),
	Vector2i(2560, 1392),
]
const NARROW := Vector2i(800, 600)
const SQUEEZED := Vector2i(700, 600)
const STATUS_SAMPLES := [
	{"cash": 1234560000.0, "population": 6789},      # 12.35万 / 6789
	{"cash": 88888000000.0, "population": 88888888}, # 888.88万 / 8888.89万
	{"cash": 0.0, "population": 0},                  # 0 / 0
]

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	for dimensions in DIMENSIONS:
		var bar := _mount(dimensions)
		if bar == null:
			_check("%s 能实例化顶栏" % dimensions, false)
			continue
		bar.update_time_state(0, 1, 1, false, 1.0)
		bar.set_era_name("石器时代")
		await process_frame
		_check("%s 首日日期与时代按原字号完整落在框内" % dimensions,
			_fits_inside(bar) and not _clipped(bar)
			and _font_size(bar, "%DateLabel") == PlayerTopBar.DATE_FONT_SIZE
			and _font_size(bar, "%EraName") == PlayerTopBar.ERA_FONT_SIZE)
		_check("%s 日期左右都留出边缘余量" % dimensions, _keeps_edge_margin(bar))
		var first_day := _metrics(bar)
		bar.update_time_state(0, 1, 28, false, 1.0)
		await process_frame
		var later_day := _metrics(bar)
		_check("%s 同一年内逐日推进不改纸框与日期列宽" % dimensions,
			is_equal_approx(first_day.block_width, later_day.block_width)
			and is_equal_approx(first_day.date_label_width, later_day.date_label_width))
		bar.update_time_state(11, 12, 30, false, 10.0)
		bar.set_era_name("帝国时代")
		await process_frame
		_check("%s 两位数年月日与新时代表述仍完整落在框内" % dimensions,
			_fits_inside(bar) and not _clipped(bar)
			and _keeps_edge_margin(bar)
			and _font_size(bar, "%DateLabel") == PlayerTopBar.DATE_FONT_SIZE)
		_free_mount(bar)

	var narrow := _mount(NARROW)
	if narrow != null:
		narrow.update_time_state(11, 12, 30, false, 1.0)
		narrow.set_era_name("帝国时代")
		await process_frame
		_check("%s 窄窗整体降字号，但依然不裁字" % NARROW,
			_font_size(narrow, "%DateLabel") < PlayerTopBar.DATE_FONT_SIZE
			and _font_size(narrow, "%DateLabel") >= PlayerTopBar.DATE_FONT_MIN_SIZE
			and _fits_inside(narrow) and not _clipped(narrow) and _keeps_edge_margin(narrow))
		print("[info] %s 字号 %d/%d 纸框 %.1f px" % [NARROW,
			_font_size(narrow, "%DateLabel"), _font_size(narrow, "%EraName"),
			float(_metrics(narrow).block_width)])
		_free_mount(narrow)

	var squeezed := _mount(SQUEEZED)
	if squeezed != null:
		squeezed.update_time_state(11, 12, 30, false, 1.0)
		squeezed.set_era_name("帝国时代")
		await process_frame
		var width: float = _metrics(squeezed).block_width
		_check("%s 极端窄窗纸框宁可变宽也不裁字" % SQUEEZED,
			_fits_inside(squeezed) and not _clipped(squeezed) and _keeps_edge_margin(squeezed))
		print("[info] %s 纸框 %.1f px" % [SQUEEZED, width])
		_free_mount(squeezed)

	await _check_status_plates()

	print("player_top_bar_fit_test: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


## 国库/人口纸签：读数再长也必须完整落在纸框内，且纸签宽度按实测字宽长，
## 不靠压字或裁字；同位数读数之间宽度不抖（数字按最宽字形 8 预留）。
func _check_status_plates() -> void:
	for dimensions in [Vector2i(1280, 720), Vector2i(2560, 1392)]:
		var bar := _mount(dimensions)
		if bar == null:
			continue
		for sample in STATUS_SAMPLES:
			bar.set_country_status(sample.cash, true, sample.population, true)
			await process_frame
			_check("%s 国库 %s / 人口 %s 完整落在纸签内"
					% [dimensions, _status_text(bar, "TreasuryButton"),
						_status_text(bar, "PopulationButton")],
				_status_text_fits(bar))
			_check("%s 两块读数都与纸边保持 Row 内边距" % dimensions,
				_status_keeps_margins(bar))
		bar.set_country_status(1234560000.0, true, 6789, true)
		await process_frame
		var short_width := _status_width(bar, "TreasuryButton")
		bar.set_country_status(4321000000.0, true, 6789, true)
		await process_frame
		_check("%s 同位数读数不改变国库纸签宽度" % dimensions,
			is_equal_approx(short_width, _status_width(bar, "TreasuryButton")))
		bar.set_country_status(88888000000.0, true, 6789, true)
		await process_frame
		_check("%s 更长的读数让纸签变宽而不是压字" % dimensions,
			_status_width(bar, "TreasuryButton") > short_width + 0.5
			and _status_text_fits(bar))
		_free_mount(bar)


func _status_entry(bar: PlayerTopBar, button_name: String) -> Dictionary:
	var button := bar.get_node("%" + button_name) as Button
	var row := button.get_node("Row") as HBoxContainer
	var icon := row.get_child(0) as Control
	var value := row.get_child(1) as Label
	var font := value.get_theme_font(&"font") as Font
	var text_width := 0.0
	if font != null:
		text_width = font.get_string_size(value.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			value.get_theme_font_size(&"font_size")).x
	return {
		"plaque": button,
		"row": row,
		"icon": icon,
		"value": value,
		"text_width": text_width,
		"pad_left": row.offset_left,
		"pad_right": -row.offset_right,
	}


func _status_text(bar: PlayerTopBar, button_name: String) -> String:
	return (_status_entry(bar, button_name).value as Label).text


func _status_width(bar: PlayerTopBar, button_name: String) -> float:
	return (_status_entry(bar, button_name).plaque as Control).size.x


## 读数 Label 必须容得下自己的字，且整条 Row 装得进纸签。
func _status_text_fits(bar: PlayerTopBar) -> bool:
	for button_name in ["TreasuryButton", "PopulationButton"]:
		var entry := _status_entry(bar, button_name)
		var value := entry.value as Label
		var row := entry.row as HBoxContainer
		var plaque := entry.plaque as Control
		var separation := float(row.get_theme_constant(&"separation"))
		var required: float = entry.pad_left + entry.pad_right + entry.icon.size.x \
			+ separation * float(row.get_child_count() - 1) + value.size.x
		if value.size.x + 0.5 < entry.text_width:
			return false
		if plaque.size.x + 0.5 < required:
			return false
	return true


## 图标不贴左纸边、读数不贴右纸边：至少留出 Row 声明的 offset。
func _status_keeps_margins(bar: PlayerTopBar) -> bool:
	for button_name in ["TreasuryButton", "PopulationButton"]:
		var entry := _status_entry(bar, button_name)
		var plaque_rect := (entry.plaque as Control).get_global_rect()
		var icon_rect := (entry.icon as Control).get_global_rect()
		var value_rect := (entry.value as Control).get_global_rect()
		if icon_rect.position.x + 0.5 < plaque_rect.position.x + entry.pad_left:
			return false
		if value_rect.end.x - 0.5 > plaque_rect.end.x - entry.pad_right:
			return false
	return true


func _mount(dimensions: Vector2i) -> PlayerTopBar:
	root.size = dimensions
	var page := Control.new()
	page.name = "Page"
	page.theme = load(THEME_PATH)
	page.size = Vector2(dimensions)
	root.add_child(page)
	var bar := (load(BAR_SCENE) as PackedScene).instantiate() as PlayerTopBar
	page.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	bar.set_country_status(100000000.0, true, 40, true)
	return bar


func _free_mount(bar: PlayerTopBar) -> void:
	var page := bar.get_parent()
	if page == null:
		return
	page.queue_free()


func _metrics(bar: PlayerTopBar) -> Dictionary:
	var date_label := bar.get_node("%DateLabel") as Label
	var era := bar.get_node("%EraName") as Label
	var block := bar.get_node("Margin/Row/DateBlock") as Button
	var row := bar.get_node("Margin/Row/DateBlock/DateRow") as HBoxContainer
	var icon := bar.get_node("%CalendarIcon") as TextureRect
	var date_font_size := date_label.get_theme_font_size("font_size")
	var era_font_size := era.get_theme_font_size("font_size")
	var date_text_width := _text_width(date_label, date_font_size)
	var era_text_width := _text_width(era, era_font_size)
	var row_pad_left := row.offset_left
	var row_pad_right := -row.offset_right
	return {
		"block_width": block.size.x,
		"block_rect": block.get_global_rect(),
		"row_pad_left": row_pad_left,
		"row_pad_right": row_pad_right,
		"icon_left": icon.get_global_rect().position.x,
		"date_label_width": date_label.size.x,
		"date_text_width": date_text_width,
		"era_label_width": era.size.x,
		"era_text_right": era.get_global_rect().position.x + era_text_width,
		"era_text_width": era_text_width,
		"date_font": date_font_size,
		"era_font": era_font_size,
	}


func _text_width(label: Label, font_size: int) -> float:
	var font := label.get_theme_font(&"font") as Font
	if font == null:
		return 0.0
	return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x


func _font_size(bar: PlayerTopBar, path: String) -> int:
	return (bar.get_node(path) as Label).get_theme_font_size("font_size")


## 纸框宽度必须容得下：图标 + 两段间距 + 两个 Label 的最小宽度 + 左右留白。
func _fits_inside(bar: PlayerTopBar) -> bool:
	var data := _metrics(bar)
	var row := bar.get_node("Margin/Row/DateBlock/DateRow") as HBoxContainer
	var icon := bar.get_node("%CalendarIcon") as TextureRect
	var separation := float(row.get_theme_constant(&"separation"))
	var required: float = icon.custom_minimum_size.x + separation * 2.0 \
		+ data.date_label_width + data.era_label_width \
		+ data.row_pad_left + data.row_pad_right
	return data.block_width + 0.5 >= required


func _clipped(bar: PlayerTopBar) -> bool:
	var data := _metrics(bar)
	return data.date_label_width + 0.5 < data.date_text_width \
		or data.era_label_width + 0.5 < data.era_text_width


## 图标不贴左纸边、时代文字不贴右纸边：都给足 DateRow 声明的 offset。
func _keeps_edge_margin(bar: PlayerTopBar) -> bool:
	var data := _metrics(bar)
	var left_gap: float = data.icon_left - data.block_rect.position.x
	var right_gap: float = data.block_rect.end.x - data.era_text_right
	return left_gap + 0.5 >= data.row_pad_left and right_gap + 0.5 >= data.row_pad_right


func _check(label: String, ok: bool) -> void:
	if ok:
		print("[PASS] " + label)
	else:
		failures += 1
		push_error("[FAIL] " + label)
