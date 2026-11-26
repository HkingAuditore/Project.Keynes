extends SceneTree

const ConvexBounds := preload("res://scripts/rendering/map_camera_convex_bounds.gd")
const MapCameraScript := preload("res://scripts/rendering/map_camera.gd")
const VisualAdapterScript := preload("res://scripts/game/world_runtime_visual_adapter.gd")

var _failures: PackedStringArray = PackedStringArray()
var _checks_run: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(cond: bool, msg: String) -> void:
	_checks_run += 1
	if not cond:
		_failures.append(msg)
		push_error("FAIL: " + msg)


func _run() -> void:
	_test_empty_and_invalid_inputs()
	_test_single_point_disk_margin()
	_test_collinear_segment_capsule()
	_test_triangle_convex_hull_and_rounded_corner()
	_test_horizontal_wrap_across_seam()
	_test_horizontal_wrap_full_ring()
	_test_build_from_explored_map_data()
	_test_camera_clamp_and_inertia_sliding()
	_test_camera_zoom_limit_and_expansion()
	_check(VisualAdapterScript != null, "visual adapter script compiles cleanly")
	_check(_checks_run >= 35, "expected all assertions to execute (ran %d)" % _checks_run)

	if _failures.is_empty():
		print("map_camera_convex_bounds_test: PASS (%d checks)" % _checks_run)
		quit(0)
	else:
		print("map_camera_convex_bounds_test: FAIL (%d/%d)" % [_failures.size(), _checks_run])
		quit(1)


func _test_empty_and_invalid_inputs() -> void:
	var empty_bounds := ConvexBounds.build_from_points(PackedVector2Array(), 88.0, 0.0)
	_check(not empty_bounds.is_active(), "empty point set must stay inactive")
	var p := Vector2(123.0, -45.0)
	_check(empty_bounds.clamp_point(p).is_equal_approx(p), "inactive bounds must not move point")
	_check(not empty_bounds.last_clamped, "inactive bounds must not report clamped")

	var null_map_bounds := ConvexBounds.build_from_explored(null, 22.0, 4.0, 0.0)
	_check(not null_map_bounds.is_active(), "null map must stay inactive")

	var bad_hex_bounds := ConvexBounds.build_from_explored(MapData.new(2, 2), 0.0, 4.0, 0.0)
	_check(not bad_hex_bounds.is_active(), "non-positive hex_size must stay inactive")


func _test_single_point_disk_margin() -> void:
	var margin := 88.0
	var b := ConvexBounds.build_from_points(PackedVector2Array([Vector2(100.0, 50.0)]), margin, 0.0)
	_check(b.is_active(), "single point bounds should be active")
	_check(b.hull.size() == 1, "single point hull size should be 1")

	var inside := Vector2(100.0 + 40.0, 50.0 - 40.0)
	_check(b.clamp_point(inside).is_equal_approx(inside), "point inside margin disk stays unchanged")
	_check(not b.last_clamped, "inside point should not set last_clamped")

	var outside := Vector2(100.0 + 200.0, 50.0)
	var clamped: Vector2 = b.clamp_point(outside)
	_check(clamped.is_equal_approx(Vector2(100.0 + margin, 50.0)), "single point clamps to margin circle")
	_check(b.last_clamped, "outside point must set last_clamped")
	_check(b.last_outward_normal.is_equal_approx(Vector2(1.0, 0.0)), "outward normal points east")


func _test_collinear_segment_capsule() -> void:
	var pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(50.0, 0.0),
		Vector2(100.0, 0.0),
	])
	var b := ConvexBounds.build_from_points(pts, 40.0, 0.0)
	_check(b.is_active(), "collinear points should be active")
	_check(b.hull.size() == 2, "collinear points reduce to segment hull")

	var clamped_north: Vector2 = b.clamp_point(Vector2(50.0, -100.0))
	_check(clamped_north.is_equal_approx(Vector2(50.0, -40.0)), "segment clamps perpendicularly")
	_check(b.last_outward_normal.is_equal_approx(Vector2(0.0, -1.0)), "segment normal points north")

	var clamped_end: Vector2 = b.clamp_point(Vector2(200.0, 0.0))
	_check(clamped_end.is_equal_approx(Vector2(140.0, 0.0)), "segment endpoint clamps to cap")


func _test_triangle_convex_hull_and_rounded_corner() -> void:
	var pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(200.0, 0.0),
		Vector2(100.0, 150.0),
		Vector2(100.0, 50.0),  # 内部点，应被凸包剔除
	])
	var margin := 88.0
	var b := ConvexBounds.build_from_points(pts, margin, 0.0)
	_check(b.hull.size() == 3, "interior point must be discarded from convex hull")

	# 凸包内部不钳制
	_check(b.clamp_point(Vector2(100.0, 50.0)).is_equal_approx(Vector2(100.0, 50.0)), "interior stays unchanged")
	_check(not b.last_clamped, "interior does not clamp")

	# 顶点 (0,0) 外侧西南角应按半径 margin 圆角外拓
	var corner_target := Vector2(-100.0, -100.0)
	var clamped_corner: Vector2 = b.clamp_point(corner_target)
	var expected_corner := Vector2(-1.0, -1.0).normalized() * margin
	_check(clamped_corner.distance_to(expected_corner) < 0.05, "corner uses rounded Minkowski margin")
	_check(b.last_outward_normal.distance_to(Vector2(-1.0, -1.0).normalized()) < 0.01, "corner outward normal accurate")


func _test_horizontal_wrap_across_seam() -> void:
	# 周期 1000，已探索区域横跨 x=0 接缝（950..990 和 10..50）
	var period := 1000.0
	var margin := 88.0
	var pts := PackedVector2Array([
		Vector2(960.0, 100.0),
		Vector2(990.0, 200.0),
		Vector2(20.0, 100.0),
		Vector2(40.0, 200.0),
	])
	var b := ConvexBounds.build_from_points(pts, margin, period)
	_check(b.is_active(), "seam-crossing bounds should be active")
	_check(not b.wraps_full_x, "small seam-crossing patch should not wrap full x")

	# 接缝处 x=0 位于展开凸包内部，不应被推开
	var at_seam := Vector2(0.0, 150.0)
	_check(b.clamp_point(at_seam).is_equal_approx(at_seam), "point on seam inside explored area is allowed")
	_check(not b.last_clamped, "seam interior not clamped")

	# 远离探索区的地图另一侧 x=500 必须被钳制回外拓边界（距 x=40 或 x=960 不超过 margin）
	var far_side := Vector2(500.0, 150.0)
	var clamped_far: Vector2 = b.clamp_point(far_side)
	_check(b.last_clamped, "opposite side of globe must be clamped")
	var dist_to_east := absf(HexUtils.wrap_min_image_dx(clamped_far.x - 40.0, period))
	var dist_to_west := absf(HexUtils.wrap_min_image_dx(clamped_far.x - 960.0, period))
	_check(minf(dist_to_east, dist_to_west) <= margin + 0.5, "clamped point stays within margin of seam patch")


func _test_horizontal_wrap_full_ring() -> void:
	# 周期 1000，每隔 100 都有探索点，最大空隙 100 <= 2 * 88 = 176 -> 东西自由环绕，仅限制南北
	var period := 1000.0
	var margin := 88.0
	var pts := PackedVector2Array()
	for i in 10:
		pts.append(Vector2(float(i) * 100.0, 200.0))
	var b := ConvexBounds.build_from_points(pts, margin, period)
	_check(b.is_active() and b.wraps_full_x, "full ring exploration enables wraps_full_x")

	var mid := Vector2(555.0, 200.0)
	_check(b.clamp_point(mid).is_equal_approx(mid), "full ring allows free x pan")
	_check(not b.last_clamped, "full ring mid y not clamped")

	var too_north := Vector2(555.0, 0.0)
	var clamped_n: Vector2 = b.clamp_point(too_north)
	_check(clamped_n.is_equal_approx(Vector2(555.0, 200.0 - margin)), "full ring still clamps north")
	_check(b.last_clamped and b.last_outward_normal.is_equal_approx(Vector2(0.0, -1.0)), "north normal set")


func _test_build_from_explored_map_data() -> void:
	var map := MapData.new(4, 4)
	var n := 16
	map.explored_arr.resize(n)
	map.explored_arr.fill(0)
	map.cell_pos_x_arr.resize(n)
	map.cell_pos_y_arr.resize(n)
	for r in 4:
		for c in 4:
			var idx := r * 4 + c
			var cube := HexUtils.offset_to_cube(c, r)
			var wp := HexUtils.cube_to_world(cube.x, cube.y, 1.0)
			map.cell_pos_x_arr[idx] = wp.x
			map.cell_pos_y_arr[idx] = wp.y

	# 未探索任何格 -> inactive
	var none_bounds := ConvexBounds.build_from_explored(map, 22.0, 4.0, 0.0)
	_check(not none_bounds.is_active(), "unexplored map stays inactive")

	# 探索中心格 (1,1) -> 外拓半径 = 4 * 22 = 88
	map.explored_arr[1 * 4 + 1] = 1
	var one_bounds := ConvexBounds.build_from_explored(map, 22.0, 4.0, 0.0)
	_check(one_bounds.is_active(), "explored map builds active bounds")
	_check(is_equal_approx(one_bounds.margin, 88.0), "4 hex radii margin equals 4 * hex_size")


func _test_camera_clamp_and_inertia_sliding() -> void:
	var cam: MapCamera = MapCameraScript.new()
	root.add_child(cam)
	cam.set_world_bounds(Rect2(-2000.0, -2000.0, 4000.0, 4000.0))
	cam.zoom = Vector2(2.0, 2.0)
	cam._target_zoom = cam.zoom

	var pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(200.0, 0.0),
		Vector2(200.0, 200.0),
		Vector2(0.0, 200.0),
	])
	var bounds := ConvexBounds.build_from_points(pts, 88.0, 0.0)
	cam.set_pan_convex_bounds(bounds)

	# 相机尝试越过东边界：应被限制到 200 + 88 = 288
	cam.position = Vector2(500.0, 100.0)
	cam._clamp_position()
	_check(cam.position.is_equal_approx(Vector2(288.0, 100.0)), "camera clamps to convex east margin")

	# 惯性向东北方向撞东墙：x 速度应清零，y 速度应保留（滑行）
	cam.position = Vector2(288.0, 100.0)
	cam._pan_velocity = Vector2(100.0, 80.0)
	cam._measuring_pan = false
	cam._update_inertia(0.05)
	_check(absf(cam._pan_velocity.x) < 0.1, "inertia kills outward normal velocity component")
	_check(cam._pan_velocity.y > 40.0, "inertia preserves tangential velocity component")

	# 关闭迷雾清除凸包限制后，相机可滚出 288
	cam.clear_pan_convex_bounds()
	cam.position = Vector2(500.0, 100.0)
	cam._clamp_position()
	_check(cam.position.is_equal_approx(Vector2(500.0, 100.0)), "clearing convex bounds restores full world pan")

	cam.queue_free()


func _test_camera_zoom_limit_and_expansion() -> void:
	var cam: MapCamera = MapCameraScript.new()
	root.add_child(cam)
	cam.set_world_bounds(Rect2(-2000.0, -2000.0, 4000.0, 4000.0))
	var vp_size := cam.get_viewport_rect().size
	_check(vp_size.x > 0.0 and vp_size.y > 0.0, "viewport has valid size for zoom test")
	var base_dim := minf(vp_size.x, vp_size.y)
	var test_margin := base_dim * 0.05
	var small_span := base_dim * 0.20
	var large_span := base_dim * 1.20
	var world_span := maxf(vp_size.x, vp_size.y) * 3.0
	cam.set_world_bounds(Rect2(-world_span * 0.5, -world_span * 0.5, world_span, world_span))

	# 开局较小的探索区域
	var small_pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(small_span, 0.0),
		Vector2(small_span, small_span),
		Vector2(0.0, small_span),
	])
	var small_bounds := ConvexBounds.build_from_points(small_pts, test_margin, 0.0)
	var expected_small_dim := small_span + test_margin * 2.0
	var expected_small_sz := Vector2(expected_small_dim, expected_small_dim)
	_check(small_bounds.bounds_size().is_equal_approx(expected_small_sz), "convex bounds_size includes 2*margin")

	cam.zoom = Vector2(0.5, 0.5)
	cam._target_zoom = cam.zoom
	cam.set_pan_convex_bounds(small_bounds)
	var expected_small_min := clampf(
		minf(vp_size.x / expected_small_dim, vp_size.y / expected_small_dim),
		cam.zoom_min,
		cam.zoom_max
	)
	_check(expected_small_min > 1.5, "small explored area lifts floor well above 1x")
	_check(is_equal_approx(cam._minimum_zoom(), expected_small_min), "minimum zoom lifts to small convex floor")
	_check(cam.zoom.x >= expected_small_min - 0.001, "setting small convex bounds lifts current zoom immediately")

	# 尝试缩放到极小倍率，必须被拦截在最小缩放地板处
	cam._set_target_zoom(0.25, vp_size * 0.5)
	_check(is_equal_approx(cam._target_zoom.x, expected_small_min), "zoom-out target clamped by convex floor")
	cam._apply_zoom_anchored(0.25, vp_size * 0.5)
	_check(cam.zoom.x >= expected_small_min - 0.001, "anchored zoom-out cannot bypass convex floor")

	# fit_to_viewport 适配小探索区，但不应把 _fit_floor_zoom 锁死在小探索区倍率
	cam.fit_to_viewport(1.0, Rect2(Vector2.ZERO, vp_size), true)
	_check(cam.zoom.x >= expected_small_min - 0.001, "fit_to_viewport respects convex zoom floor")

	# 探索扩大后：最小缩放地板应自动放宽
	var large_pts := PackedVector2Array([
		Vector2(-large_span * 0.5, -large_span * 0.5),
		Vector2(large_span * 0.5, -large_span * 0.5),
		Vector2(large_span * 0.5, large_span * 0.5),
		Vector2(-large_span * 0.5, large_span * 0.5),
	])
	var large_bounds := ConvexBounds.build_from_points(large_pts, test_margin, 0.0)
	cam.set_pan_convex_bounds(large_bounds)
	_check(cam._minimum_zoom() < expected_small_min - 0.5, "expanding exploration lowers minimum zoom floor")

	# 清除凸包（关雾）后恢复世界级缩放地板
	cam.clear_pan_convex_bounds()
	var world_cover := clampf(maxf(vp_size.x / world_span, vp_size.y / world_span), cam.zoom_min, cam.zoom_max)
	_check(is_equal_approx(cam._minimum_zoom(), world_cover), "clearing convex bounds restores world cover zoom floor")

	cam.queue_free()
