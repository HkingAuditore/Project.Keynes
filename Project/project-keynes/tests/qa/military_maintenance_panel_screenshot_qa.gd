extends SceneTree

## 军事维护支出块的渲染态验收（**需要渲染，不要加 --headless**）。
##
##   godot --path Project/project-keynes -s res://tests/qa/military_maintenance_panel_screenshot_qa.gd
##
## 覆盖设计要求的三个档位：1280×720、1920×1080（宽屏）、720×1280（移动竖向）。
## 每个档位都做两件事：
##   1. 把真实的 `military_spending_block.gd` 放进带主题的背景里截图（PNG 落到
##      `res://tmp/military_maintenance_qa/`），供人眼复核字重、撕纸质感与对齐；
##   2. 断言几何：块不出视口、明细段右缘不越过背景、三档都能渲染出维护行。
## 数据是固定 fixture —— 这一层只验证版面与材质，不验证实时仿真。

const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/military_maintenance_qa"
const BlockScript = preload("res://scripts/ui/components/military_spending_block.gd")
const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")
const FacadeScript = preload("res://scripts/military/military_facade.gd")

const SETTLE_SECONDS := 0.45

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	# 项目跑 1.25 倍桌面缩放，所以窗口像素要放大到逻辑像素的 1.25 倍。
	var tiers := [
		{"name": "1280x720", "window": Vector2i(1600, 900)},
		{"name": "1920x1080", "window": Vector2i(2400, 1350)},
		{"name": "720x1280", "window": Vector2i(900, 1600)},
	]
	for tier in tiers:
		await _run_tier(tier)
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	print("military maintenance panel qa: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _run_tier(tier: Dictionary) -> void:
	var label := String(tier["name"])
	DisplayServer.window_set_size(tier["window"] as Vector2i)
	root.size = tier["window"] as Vector2i
	await _settle_viewport()
	var logical := root.get_visible_rect().size
	print("  [info] %s window %s -> UI %s" % [label, tier["window"], logical])

	var backdrop := ColorRect.new()
	backdrop.color = Color("e4d9bf")
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame

	# 国家面板的军事章把支出块放在 460px 的档案列里；窄档用可用宽度。
	var column := minf(460.0, logical.x - 48.0)
	var holder := MarginContainer.new()
	holder.set_anchors_preset(Control.PRESET_TOP_LEFT)
	holder.custom_minimum_size = Vector2(column, 0.0)
	holder.add_theme_constant_override("margin_left", 12)
	holder.add_theme_constant_override("margin_right", 12)
	holder.add_theme_constant_override("margin_top", 12)
	backdrop.add_child(holder)
	await process_frame

	var block := BlockScript.new() as Control
	holder.add_child(block)
	await process_frame
	block.set_state(CountryViewModelScript.military_spending_model(
		_country_snapshot(), _maintenance_model()))
	await _settle()

	await _capture("maintenance_%s" % label.replace("x", "_"))

	var rows: Array = block.maintenance_row_texts()
	_check("%s: the detail section renders maintenance rows" % label,
		rows.size() > 0, str(rows.size()))
	_check("%s: the block fits the dossier column" % label,
		block.get_combined_minimum_size().x <= column,
		"min=%.1f column=%.1f" % [block.get_combined_minimum_size().x, column])
	var detail = block.get("_maintenance_box")
	_check("%s: the detail box stays inside the backdrop" % label,
		detail is Control and
		(detail as Control).get_global_rect().end.x <= backdrop.get_global_rect().end.x + 0.5,
		"%s vs %s" % [
			(detail as Control).get_global_rect().end.x if detail is Control else -1.0,
			backdrop.get_global_rect().end.x])

	holder.queue_free()
	backdrop.queue_free()
	await process_frame


func _country_snapshot() -> Dictionary:
	return {
		"ok": true, "has_policy": true,
		"spend_payroll_30": 3000000, "spend_upkeep_30": 1500000,
		"spend_procurement_30": 600000,
		"budget_enabled": true, "budget_share_bp": 3000,
		# The envelope slider reads the precomputed daily envelope, not the raw
		# share; without it every channel printed 每日 0 in the first screenshot.
		"budget_envelope_daily": 1800000,
		"budget_wage_daily": 1080000,
		"budget_upkeep_bp": 3000, "budget_upkeep_daily": 540000,
		"budget_procurement_daily": 180000,
		"training": [],
	}


## 与 `tests/military/military_maintenance_view_model_test.gd` 同一份快照 fixture，
## 让截图和断言看到的是同一组数据（1 项失修、3 座建筑、1 个缺货的装备组）。
func _maintenance_model() -> Dictionary:
	var snapshot := {
		"country_slot": PackedInt32Array([1, 1, 1, 1, 1]),
		"cell": PackedInt32Array([42, 42, 43, 43, 44]),
		"kind": PackedInt32Array([0, 0, 0, 1, 0]),
		"object_id": PackedInt32Array([1, 2, 0, 1, 0]),
		"units": PackedInt64Array([3, 1, 2, 400, 1]),
		"daily_need_goods": PackedInt64Array([3000, 1000, 2000, 500, 30]),
		"stock_goods": PackedInt64Array([3000, 500, 8000, 100, 120]),
		"inbound_goods": PackedInt64Array([0, 0, 0, 200, 0]),
		"ratio_bp": PackedInt32Array([10000, 5000, 9000, 2000, 10000]),
		"days_cover_x10": PackedInt32Array([35, 15, 40, 5, 40]),
		"disrepair": PackedInt32Array([0, 1, 0, 0, 0]),
		"shortage_reason": PackedInt32Array([0, 1, 0, 3, 0]),
	}
	var shaped: Dictionary = FacadeScript.shape_maintenance(snapshot, _catalog())
	return {"supported": true, "summary": shaped.get("summary", {}),
		"rows": shaped.get("rows", [])}


func _catalog() -> Dictionary:
	return {
		"state_buildings": [
			{"id": "warrior_lodge", "name": "战士营地"},
			{"id": "earthen_rampart", "name": "夯土城垣"},
		],
		"units": [
			{"id": "militia", "name": "民兵"},
			{"id": "bronze_spearmen", "name": "青铜矛兵"},
		],
	}


func _capture(name: String) -> void:
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT, name]
	var error := image.save_png(ProjectSettings.globalize_path(path))
	_check("screenshot %s written" % name, error == OK, "%s (err %d)" % [path, error])


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %s%s" % ["PASS" if ok else "FAIL", label,
		"" if detail.is_empty() else " :: " + detail])
	if not ok:
		_failures.append(label)


func _settle() -> void:
	var frames := int(ceil(SETTLE_SECONDS * 60.0))
	for _i in range(frames):
		await process_frame


func _settle_viewport() -> void:
	# 窗口尺寸变化要几帧才传导到 viewport 与 Control 布局。
	for _i in range(6):
		await process_frame
