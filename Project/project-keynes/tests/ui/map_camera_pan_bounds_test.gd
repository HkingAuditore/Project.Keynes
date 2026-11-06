extends SceneTree

## [pan-strict 2026-11-03] 相机不得把视口推出世界矩形。
##
## 回归背景：上一版 _clamped_position() 留了 0.6 × 半视口的 slack（"至少保留 40% 视口
## 能看到地图"），玩家把地图上下推出边界后看到的就是 Viewport 的 clear color 灰底，
## 顶栏 / 面板背后一整条，实机反馈"特别丑陋"。本测试锁住三条不变量：
##   1) 四个方向的极端平移都被夹回世界矩形内（视口完全落在世界内）；
##   2) 世界比视口小的异常态该轴居中，不会出现单边灰带；
##   3) fill_safe_area 铺满把最小倍率抬到"盖住整块视口"，且溢出轴仍可拖动。
##
## 运行：godot --headless --path Project/project-keynes \
##          --script tests/ui/map_camera_pan_bounds_test.gd

const EPS := 0.5

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	# QA 入口会在 _ready 里按 pk_debug.cfg 强压倍率 8 秒，测试必须关掉它。
	camera.set("_qa_zoom", 0.0)
	camera.set("_qa_zoom_until_ms", 0)
	await process_frame
	var vp := root.get_viewport().get_visible_rect().size

	# 世界比视口大，且宽高比与视口不同（高度刚好铺满时宽度仍可拖）。
	var world := Rect2(Vector2(-44.0, -44.0), Vector2(vp.x * 3.0, vp.y * 2.0))
	camera.set_world_bounds(world)
	camera.set_horizontal_wrap(0.0, false)
	_set_zoom(camera, 1.0)

	for offset in [
			Vector2(-100000.0, -100000.0),
			Vector2(100000.0, 100000.0),
			Vector2(-100000.0, 100000.0),
			Vector2(100000.0, -100000.0),
			Vector2(0.0, -100000.0),
	]:
		camera.position = offset
		camera.call("_clamp_position")
		_expect(_view_inside(camera, world),
			"极端平移被夹在世界内 %s" % str(offset))

	# 世界比视口矮：该轴居中（居中不会让一侧多露灰）。
	var short_world := Rect2(Vector2.ZERO, Vector2(vp.x * 2.0, vp.y * 0.5))
	camera.set_world_bounds(short_world)
	camera.position = Vector2(-5000.0, 5000.0)
	camera.call("_clamp_position")
	_expect(is_equal_approx(camera.position.y,
			short_world.position.y + short_world.size.y * 0.5),
		"世界比视口小时该轴居中")
	# 该轴必然露白（世界本来就比视口小），但必须两侧对称：一侧多露就是上一版那种灰带。
	var view_rect: Rect2 = camera.current_world_view_rect()
	_expect(is_equal_approx(
			view_rect.position.y + view_rect.size.y * 0.5,
			short_world.position.y + short_world.size.y * 0.5),
		"世界比视口小时灰边上下对称")

	# 铺满（fill_safe_area）：地板必须盖住"整块视口"，不是更小的 safe_area。
	camera.set_world_bounds(world)
	var safe := Rect2(Vector2(0.0, 80.0),
		Vector2(vp.x - 400.0, vp.y - 80.0 - 90.0))
	camera.fit_to_viewport(1.0, safe, true)
	var cover := maxf(vp.x / world.size.x, vp.y / world.size.y)
	_expect(camera.zoom.x >= cover - 0.001,
		"铺满倍率盖住整块视口（zoomed=%.4f cover=%.4f）" % [camera.zoom.x, cover])
	_expect(is_equal_approx(float(camera.get("_fit_floor_zoom")), camera.zoom.x),
		"铺满倍率登记为最小倍率地板")
	_expect(_view_inside(camera, world), "铺满后视口完全落在世界内（不露灰底）")

	var fitted := camera.position
	camera.position = fitted + Vector2(-100000.0, -100000.0)
	camera.call("_clamp_position")
	_expect(camera.position.x < fitted.x - 1.0,
		"铺满后仍能沿溢出轴拖动")
	_expect(is_equal_approx(camera.position.y, fitted.y),
		"铺满轴被严格夹住（该方向本来就没有更多地图）")

	# 缩回地板以下：_set_target_zoom / 捏合都必须被地板挡住。
	camera.call("_set_target_zoom", 0.01, vp * 0.5)
	_expect(float(camera.get("_target_zoom").x) >= cover - 0.001,
		"交互缩放不能降到会露灰底的倍率")

	# 视口/世界变化：地板跟着抬，并把已越界的倍率收回来。
	var shrunk := Rect2(Vector2(-44.0, -44.0), Vector2(vp.x * 1.35, vp.y * 0.9))
	camera.set_world_bounds(shrunk)
	camera.call("_on_viewport_size_changed")
	var shrunk_cover := maxf(vp.x / shrunk.size.x, vp.y / shrunk.size.y)
	_expect(camera.zoom.x >= shrunk_cover - 0.001,
		"世界/视口变化后地板重新抬到铺满（zoomed=%.4f cover=%.4f）"
			% [camera.zoom.x, shrunk_cover])
	_expect(_view_inside(camera, shrunk), "地板抬高后视口仍完整落在世界内")

	print("=== camera pan bounds: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _set_zoom(camera: MapCamera, value: float) -> void:
	camera.zoom = Vector2(value, value)
	camera.set("_target_zoom", camera.zoom)
	camera.set("_fit_floor_zoom", 0.0)


func _view_inside(camera: MapCamera, bounds: Rect2) -> bool:
	return _view_inside_axis(camera, bounds, 0) and _view_inside_axis(camera, bounds, 1)


## axis: 0 = x, 1 = y。
func _view_inside_axis(camera: MapCamera, bounds: Rect2, axis: int) -> bool:
	var rect: Rect2 = camera.current_world_view_rect()
	var lo: float = rect.position[axis]
	var hi: float = rect.end[axis]
	var b_lo: float = bounds.position[axis]
	var b_hi: float = bounds.end[axis]
	return lo >= b_lo - EPS and hi <= b_hi + EPS


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
