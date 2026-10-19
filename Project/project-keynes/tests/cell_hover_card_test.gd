extends SceneTree

## 悬停卡：几何、放置、密度档、抑制与 payload 渲染的冒烟测试。
## 不加载 player_game.tscn，只验证组件自身契约。

const CARD_SCENE := "res://scenes/ui/cell_hover_card.tscn"

var _failures: Array[String] = []


func _initialize() -> void:
	# SceneTree._initialize 早于首帧：Control 的 _ready / @onready 还没跑，
	# 所以把断言放到第一帧之后。
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	_test_placement()
	_test_density_bands()
	_test_card_contract()
	_test_cell_availability()
	_test_camera_accessors()
	if _failures.is_empty():
		print("[cell-hover-card] PASS")
		quit(0)
	else:
		for message in _failures:
			printerr("[cell-hover-card] FAIL: %s" % message)
		quit(1)


func _test_placement() -> void:
	var safe := Rect2(0, 0, 1920, 1080)
	var top_left := CellHoverCard.placement_rect(Vector2(20, 20), Vector2(1920, 1080), safe)
	if top_left.position != Vector2(36, 38):
		_failures.append("默认应右下偏移 (16,18)，实际 %s" % top_left.position)
	if top_left.size != CellHoverCard.CARD_SIZE:
		_failures.append("卡片矩形尺寸应恒为 CARD_SIZE")

	var bottom_right := CellHoverCard.placement_rect(
		Vector2(1900, 1060), Vector2(1920, 1080), safe)
	if bottom_right.end.x > safe.end.x or bottom_right.end.y > safe.end.y:
		_failures.append("右下角卡片越出安全区: %s" % bottom_right)
	if bottom_right.position.x >= 1900.0 or bottom_right.position.y >= 1060.0:
		_failures.append("右下角应同时向左上翻转: %s" % bottom_right.position)

	var inset := Rect2(200, 100, 1200, 700)
	var clamped := CellHoverCard.placement_rect(Vector2(1390, 790), Vector2(1920, 1080), inset)
	if clamped.position.x < inset.position.x + CellHoverCard.EDGE_MARGIN - 0.01 \
			or clamped.end.x > inset.end.x - CellHoverCard.EDGE_MARGIN + 0.01:
		_failures.append("水平未夹进安全区: %s" % clamped)

	var tiny := CellHoverCard.placement_rect(
		Vector2(10, 10), Vector2(300, 200), Rect2(0, 0, 300, 200))
	if tiny.size != Vector2.ZERO:
		_failures.append("安全区小于卡片时应不出卡")


func _test_density_bands() -> void:
	var cases := {0.01: 1, 0.10: 2, 0.40: 3, 0.70: 4, 0.95: 5}
	for ratio in cases:
		var level := CellInspectorViewModel.resource_density_level(float(ratio))
		if level != int(cases[ratio]):
			_failures.append("密度 %.2f 应为 %d 档，实际 %d" % [
				float(ratio), int(cases[ratio]), level])
	var names := ["贫乏", "稀少", "可采", "富集", "丰饶"]
	for i in names.size():
		var band := CellInspectorViewModel.resource_density_band(float(i) * 0.2 + 0.01)
		if band != names[i]:
			_failures.append("第 %d 档文案应为 %s，实际 %s" % [i + 1, names[i], band])


func _test_card_contract() -> void:
	var packed := load(CARD_SCENE) as PackedScene
	if packed == null:
		_failures.append("无法加载 cell_hover_card.tscn")
		return
	var card := packed.instantiate() as CellHoverCard
	if card == null:
		_failures.append("cell_hover_card.tscn 根节点不是 CellHoverCard")
		return
	root.add_child(card)

	if card.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_failures.append("卡片必须 MOUSE_FILTER_IGNORE，否则会吃掉地图点击")
	if card.size != CellHoverCard.CARD_SIZE:
		_failures.append("卡片初始尺寸应为 %s，实际 %s" % [CellHoverCard.CARD_SIZE, card.size])
	if card.visible:
		_failures.append("卡片初始必须隐藏")

	var emitted: Array[int] = []
	card.payload_applied.connect(func(idx: int) -> void: emitted.append(idx))
	card.apply_payload(_payload("1:1:0", 7, true), false)
	if not card.visible:
		_failures.append("apply_payload 后应显示")
	if card.current_cell_index() != 7:
		_failures.append("current_cell_index 应为 7")
	if emitted.size() != 1:
		_failures.append("首次 apply_payload 应发一次 payload_applied")
	card.apply_payload(_payload("2:1:0", 8, true), false)
	if emitted.size() != 2:
		_failures.append("换格应再发 payload_applied")

	var title := card.get_node("Paper/Body/Header/Text/Title") as Label
	if title.text != "长安":
		_failures.append("标题未写入: %s" % title.text)
	var value := card.get_node("Paper/Body/PopRow/Value") as Label
	if value.text != "1.2万":
		_failures.append("人口数值未写入: %s" % value.text)
	var tag3 := card.get_node("Paper/Body/TagRow/Tag3") as Label
	if tag3.text != "温带 · 温和":
		_failures.append("气候签未写入: %s" % tag3.text)
	var chip1 := card.get_node("Paper/Body/ResourceRow/Chip1") as PanelContainer
	if not chip1.visible:
		_failures.append("有资源时 Chip1 应可见")
	var pips := chip1.get_node("Line/Info/DensityRow/Pips") as HBoxContainer
	var lit := 0
	for child in pips.get_children():
		if (child as ColorRect).color == UITokens.DOSSIER_BRASS:
			lit += 1
	if lit != 4:
		_failures.append("4 档资源应点亮 4 枚密度方块，实际 %d" % lit)

	card.apply_payload(_payload("3:1:0", 9, false), false)
	var note := card.get_node("Paper/Body/ResourceRow/Note") as Label
	if not note.visible or note.text != "此地无明显自然资源":
		_failures.append("无资源时应显示空态说明")
	if chip1.visible:
		_failures.append("无资源时 Chip1 应隐藏")

	card.set_suppressed(true)
	if card.visible:
		_failures.append("set_suppressed(true) 应立即隐藏")
	card.set_suppressed(false)
	card.queue_free()


func _test_cell_availability() -> void:
	var map := MapData.new(2, 1)
	map.visible_arr = PackedByteArray([1, 0])
	map.explored_arr = PackedByteArray([0, 1])
	var packed := load(CARD_SCENE) as PackedScene
	var card := packed.instantiate() as CellHoverCard
	root.add_child(card)
	card.configure(map, null, 22.0, null, Callable(), Callable())
	if not card.is_cell_available(0):
		_failures.append("当前可见的格子应可出卡")
	if card.is_cell_available(1):
		_failures.append("已探索但不可见的格子不应出卡")
	if card.is_cell_available(99):
		_failures.append("越界索引不应出卡")
	card.queue_free()


func _test_camera_accessors() -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	if camera.is_panning():
		_failures.append("静止相机不应报告平移")
	if camera.is_zooming():
		_failures.append("静止相机不应报告缩放")
	camera._pan_active = true
	if not camera.is_panning():
		_failures.append("_pan_active 时 is_panning 应为真")
	camera._pan_active = false
	camera._target_zoom = Vector2(2.0, 2.0)
	if not camera.is_zooming():
		_failures.append("目标缩放未到位时 is_zooming 应为真")
	camera._target_zoom = camera.zoom
	if camera.is_zooming():
		_failures.append("缩放到位后 is_zooming 应为假")
	camera.queue_free()


func _payload(key: String, cell_index: int, with_resources: bool) -> Dictionary:
	var resources: Array = []
	if with_resources:
		resources = [{
			"id": "timber", "name": "木材", "icon": "resource.wood",
			"density_ratio": 0.62, "density_level": 4, "density_name": "富集",
		}, {
			"id": "iron_ore", "name": "铁矿", "icon": "resource.iron",
			"density_ratio": 0.4, "density_level": 3, "density_name": "可采",
		}]
	return {
		"ok": true, "cache_key": key, "cell_index": cell_index, "day": 1,
		"title": "长安", "title_kind": "settlement", "region": "区域 12,8",
		"country_name": "大秦", "country_owned": true, "country_known": true,
		"terrain_name": "温带草原", "landform_name": "平原", "climate_zone": "温带",
		"tags": [
			{"kind": "landform", "name": "平原", "color": UITokens.DOSSIER_UMBER},
			{"kind": "terrain", "name": "温带草原", "color": UITokens.ECO},
			{"kind": "climate", "name": "温带 · 温和", "color": UITokens.CLIMATE},
		],
		"population": 12450, "population_text": "1.2万", "population_pending": false,
		"settled": true, "settlement_tier": "乡村", "tier_pending": false,
		"resources": resources,
		"resource_note": "" if with_resources else "此地无明显自然资源",
		"resource_gated": false,
	}


func _fail(message: String) -> void:
	_failures.append(message)
