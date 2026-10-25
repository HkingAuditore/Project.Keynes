extends Control

## 常驻近景告警。仅投影屏幕内可见格，批量读 committed economy；不推进模拟。
const TITLES := ["生活物资短缺", "工业品短缺", "消费品短缺", "阶层不满",
    "正在干旱", "正在洪泛", "失业率高", "建筑岗位空缺"]
const CLASS_NAMES := {"general": "一般居民", "farmer": "农民", "worker": "工人",
    "technology": "知识阶层", "merchant": "商人", "capitalist": "资本所有者",
    "landowner": "地主", "aristocrat": "贵族", "artisan": "工匠"}
const ATLAS: Texture2D = preload("res://assets/vfx/situation/situation_badges.png")

var _map: MapData
var _camera: Camera2D
var _host
var _economy
var _adapter: DCViewAdapter
var _hex_size := 22.0
var _wrap := 0.0
var _near := false
var _dirty := true
var _query_due := 0.0
var _time := 0.0
var _cursor := 0
var _candidates := PackedInt32Array()
var _rows: Dictionary = {}
var _icons: Array[Texture2D] = []
var _hits: Array[Dictionary] = []
var _last_transform := Transform2D()
var _last_size := Vector2.ZERO
var _last_fog := false
var _last_zoom := -1.0
var _tooltip: PanelContainer
var _tooltip_label: Label
var _hover_key := ""
var _mouse_position := Vector2(-1, -1)
var _last_query_ms := 0.0
var _last_batch_size := 0
var _query_count := 0
var _scan_count := 0


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    _make_icons()
    _tooltip = PanelContainer.new()
    _tooltip.theme_type_variation = &"PKPaperPopup"
    _tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _tooltip_label = Label.new()
    _tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _tooltip_label.add_theme_font_size_override("font_size", 14)
    _tooltip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _tooltip_label.custom_minimum_size.x = 270
    _tooltip.add_child(_tooltip_label)
    add_child(_tooltip)
    _tooltip.hide()


func _make_icons() -> void:
    if not _icons.is_empty():
        return
    var image := ATLAS.get_image()
    var tile := Vector2(ATLAS.get_width() / 4.0, ATLAS.get_height() / 2.0)
    for kind in range(8):
        var origin := Vector2(kind % 4, kind / 4) * tile
        var region := Rect2i(Vector2i(origin), Vector2i(tile))
        # 冷路径只算 alpha 包围盒，原图与透明通道保持不变。
        if image != null:
            var used := image.get_region(region).get_used_rect()
            if used.has_area():
                region = Rect2i(region.position + used.position, used.size)
        var icon := AtlasTexture.new()
        icon.atlas = ATLAS
        icon.region = Rect2(region)
        icon.filter_clip = true
        _icons.append(icon)


func configure(map: MapData, camera: Camera2D, host, economy,
        adapter: DCViewAdapter) -> void:
    _disconnect_context()
    _map = map
    _camera = camera
    _host = host
    _economy = economy
    _adapter = adapter
    _hex_size = float(host.hex_size)
    _wrap = float(host.map_wrap_period_x())
    _rows.clear()
    _hits.clear()
    _candidates.clear()
    _cursor = 0
    _near = false
    _dirty = true
    _last_zoom = -1.0
    _query_due = 0.0
    _host.daily_tick_completed.connect(_on_daily_commit)
    _host.simulation_committed.connect(_on_worker_commit)
    _hide_tooltip()
    queue_redraw()


func _disconnect_context() -> void:
    if not is_instance_valid(_host):
        return
    if _host.daily_tick_completed.is_connected(_on_daily_commit):
        _host.daily_tick_completed.disconnect(_on_daily_commit)
    if _host.simulation_committed.is_connected(_on_worker_commit):
        _host.simulation_committed.disconnect(_on_worker_commit)


func _exit_tree() -> void:
    _disconnect_context()


func _on_daily_commit(_report: Dictionary) -> void:
    _dirty = true
    queue_redraw()


func _on_worker_commit(_from: int, _to: int, _generation: int) -> void:
    _dirty = true
    queue_redraw()


func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        _mouse_position = event.position


func _process(delta: float) -> void:
    _time += delta
    if _map == null or _camera == null or not is_visible_in_tree():
        _hide_tooltip()
        return
    var width := sqrt(3.0) * _hex_size * _camera.zoom.x
    var near_now := width >= (UITokens.MAP_SITUATION_HIDE_WIDTH if _near
        else UITokens.MAP_SITUATION_SHOW_WIDTH)
    if not near_now:
        if _near:
            _near = false
            _hits.clear()
            _rows.clear()
            _candidates.clear()
            _hide_tooltip()
            queue_redraw()
        return
    var transform := get_viewport().get_canvas_transform()
    var fog := bool(_host.is_fog_of_war_enabled())
    # 撤销视野立即清掉已绘制命令，不等待下一轮经济批次。
    if fog:
        var visible := _map.visible_arr
        for cell in _rows.keys():
            if int(cell) >= visible.size() or visible[int(cell)] == 0:
                _rows.erase(cell)
                _dirty = true
                queue_redraw()
    if not _near or transform != _last_transform or size != _last_size \
            or fog != _last_fog or not is_equal_approx(_last_zoom, _camera.zoom.x):
        _near = true
        _last_transform = transform
        _last_size = size
        _last_fog = fog
        _last_zoom = _camera.zoom.x
        _dirty = true
        queue_redraw()
    # Privacy is enforced again at drawing/tooltip time, even while a read is pending.
    if _time >= _query_due:
        _query_due = _time + UITokens.MAP_SITUATION_REFRESH_SECONDS
        if _dirty:
            _rebuild_candidates()
        if _dirty or not _candidates.is_empty():
            _query_batch()
    _update_tooltip()


func _rebuild_candidates() -> void:
    var previous := _candidates.duplicate()
    _candidates.clear()
    _scan_count = 0
    var view := Rect2(Vector2.ZERO, get_viewport_rect().size).grow(40.0)
    var inverse := get_viewport().get_canvas_transform().affine_inverse()
    var start := inverse * view.position
    var end := inverse * view.end
    var first_row := maxi(0, floori(start.y / (_hex_size * 1.5)) - 1)
    var last_row := mini(_map.height - 1, ceili(end.y / (_hex_size * 1.5)) + 1)
    var column_step := sqrt(3.0) * _hex_size
    var seen := {}
    for row in range(first_row, last_row + 1):
        var shift := 0.5 * float(row & 1)
        var first_col := floori(start.x / column_step - shift) - 1
        var last_col := ceili(end.x / column_step - shift) + 1
        for col in range(first_col, last_col + 1):
            _scan_count += 1
            var cube := HexUtils.offset_to_cube(posmod(col, _map.width), row)
            var cell := _map.get_cell_by_cube(cube)
            if cell == null or seen.has(cell.index) or not _can_show(cell.index):
                continue
            seen[cell.index] = true
            _candidates.append(cell.index)
    # Center-first makes the bound predictable on very large displays.
    var sorted: Array = Array(_candidates)
    var distances := {}
    for cell in _candidates:
        distances[cell] = _screen_center(cell).distance_squared_to(view.get_center())
    sorted.sort_custom(func(a, b):
        return distances[a] < distances[b] if distances[a] != distances[b] else a < b)
    _candidates = PackedInt32Array(sorted.slice(0, UITokens.MAP_SITUATION_VISIBLE_CAP))
    if _candidates != previous:
        _cursor = 0
    var retained := {}
    for cell in _candidates:
        retained[cell] = true
    for cell in _rows.keys():
        if not retained.has(cell) or not _can_show(int(cell)):
            _rows.erase(cell)


func _query_batch() -> void:
    _dirty = false
    if _candidates.is_empty():
        _rows.clear()
        queue_redraw()
        return
    var batch := PackedInt32Array()
    var end := mini(_cursor + UITokens.MAP_SITUATION_BATCH_CELLS, _candidates.size())
    for index in range(_cursor, end):
        var cell := _candidates[index]
        if _can_show(cell):
            batch.append(cell)
    batch.sort()
    _cursor = end if end < _candidates.size() else 0
    _last_batch_size = batch.size()
    var started := Time.get_ticks_usec()
    var packet: Dictionary = _economy.cell_situation_snapshot(batch) \
        if _economy != null else {}
    _last_query_ms = (Time.get_ticks_usec() - started) / 1000.0
    _query_count += 1
    apply_snapshot(packet)
    # Weather alerts do not depend on economy availability or settlement population.
    for cell in batch:
        _update_weather(cell)
    queue_redraw()


func apply_snapshot(packet: Dictionary) -> void:
    if not bool(packet.get("ok", false)) or not bool(packet.get("committed", false)):
        return
    var cells: PackedInt32Array = packet.get("cell_indices", PackedInt32Array())
    var flags: PackedByteArray = packet.get("flags", PackedByteArray())
    var severity: PackedInt32Array = packet.get("severity_q16", PackedInt32Array())
    var causes: PackedInt32Array = packet.get("cause_good_ids", PackedInt32Array())
    var classes: PackedInt32Array = packet.get("worst_class_ids", PackedInt32Array())
    var class_ids: PackedStringArray = packet.get("class_ids", PackedStringArray())
    var days: PackedInt64Array = packet.get("state_days", PackedInt64Array())
    if cells.size() != flags.size() or severity.size() != cells.size() * 8 \
            or causes.size() != cells.size() * 3 or classes.size() != cells.size() \
            or days.size() != cells.size():
        return
    for index in range(cells.size()):
        var cell := int(cells[index])
        if not _can_show(cell):
            _rows.erase(cell)
            continue
        var class_id := int(classes[index])
        _rows[cell] = {"flags": int(flags[index]),
            "severity": severity.slice(index * 8, index * 8 + 8),
            "causes": causes.slice(index * 3, index * 3 + 3),
            "class_id": String(class_ids[class_id]) if class_id >= 0 \
                and class_id < class_ids.size() else "",
            "day": int(days[index])}
    queue_redraw()


func _update_weather(cell: int) -> void:
    if not _can_show(cell) or _adapter == null:
        _rows.erase(cell)
        return
    var row: Dictionary = _rows.get(cell, {"flags": 0,
        "severity": PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0]),
        "causes": PackedInt32Array([-1, -1, -1]), "class_id": "", "day": -1})
    var mask := int(row.flags) & ~((1 << 4) | (1 << 5))
    if not _adapter.get_is_water(cell) and _adapter.get_weather_field_init(cell) \
            and _adapter.get_weather_type(cell) == WeatherType.WT.DROUGHT:
        mask |= 1 << 4
        row.severity[4] = roundi(clampf(_adapter.get_weather_intensity(cell), 0.0, 1.0) * 65535)
    if _adapter.get_cover(cell) == CoverType.CV.FLOODING:
        mask |= 1 << 5
        row.severity[5] = 65535
    row.flags = mask
    _rows[cell] = row


func _can_show(cell: int) -> bool:
    return _map != null and cell >= 0 and cell < _map.cell_count() and \
        (not _host.is_fog_of_war_enabled() or (cell < _map.visible_arr.size() \
        and _map.visible_arr[cell] != 0))


func _screen_center(cell: int) -> Vector2:
    var hex := _map.cell_at(cell)
    var world := HexUtils.cube_to_world(hex.q, hex.r, _hex_size)
    world = HexUtils.nearest_display_world(world, _camera.global_position.x, _wrap)
    return get_viewport().get_canvas_transform() * world


func _draw() -> void:
    _hits.clear()
    if not _near or _map == null or _icons.size() != 8:
        return
    var side := UITokens.MAP_SITUATION_ICON_SIZE
    for cell in _rows:
        if not _can_show(int(cell)):
            continue
        var row: Dictionary = _rows[cell]
        var kinds: Array[int] = []
        for kind in range(8):
            if int(row.flags) & (1 << kind):
                kinds.append(kind)
        if kinds.is_empty():
            continue
        var center := _screen_center(int(cell))
        if not get_viewport_rect().grow(50).has_point(center):
            continue
        var columns := mini(3, kinds.size())
        var row_count := ceili(kinds.size() / 3.0)
        var top := center + Vector2(-columns * side * 0.5,
            -_hex_size * _camera.zoom.x * 0.5 - row_count * side)
        for index in range(kinds.size()):
            var kind := kinds[index]
            var rect := Rect2(top + Vector2(index % 3, index / 3) * side, Vector2.ONE * side)
            draw_texture_rect(_icons[kind], rect, false)
            _hits.append({"rect": rect, "cell": cell, "kind": kind})


func _update_tooltip() -> void:
    if _tooltip == null:
        return
    var hovered := get_viewport().gui_get_hovered_control()
    if hovered != null and hovered != self:
        _hide_tooltip()
        return
    for hit in _hits:
        if hit.rect.has_point(_mouse_position) and _can_show(int(hit.cell)):
            var key := "%d:%d" % [int(hit.cell), int(hit.kind)]
            # Re-apply text as data changes; the tooltip node itself is stable.
            _hover_key = key
            _tooltip_label.text = tooltip_for(int(hit.cell), int(hit.kind))
            _tooltip.position = (_mouse_position + Vector2(16, 16)).clamp(
                Vector2(4, 4), get_viewport_rect().size - Vector2(300, 140))
            _tooltip.show()
            return
    _hide_tooltip()


func tooltip_for(cell: int, kind: int) -> String:
    var row: Dictionary = _rows.get(cell, {})
    if row.is_empty():
        return ""
    var score := float(row.severity[kind]) * 100.0 / 65536.0
    var text := String(TITLES[kind])
    if kind < 3:
        var good := int(row.causes[kind])
        var name := String(_economy.good_display_name(good)) if _economy != null and good >= 0 else ""
        text += "\n%s缺口 %.0f%%" % [name + "：" if not name.is_empty() else "", score]
    elif kind == 3:
        var cls := String(row.class_id)
        text += "\n%s：综合满意度 %.0f%%" % [String(CLASS_NAMES.get(cls, cls)), 100.0 - score]
    elif kind == 6:
        text += "\n失业人口占比 %.0f%%" % score
    elif kind == 7:
        text += "\n当前用工计划中 %.0f%% 的岗位空缺\n也可能受到职业门槛或工资吸引力限制。" % score
    elif kind == 4:
        text += "\n当前天气已判定为干旱。"
    else:
        text += "\n当前地表处于洪泛状态。"
    if kind not in [4, 5] and int(row.day) >= 0:
        text += "\n最近本地结算：第 %d 天" % int(row.day)
    return text


func _hide_tooltip() -> void:
    _hover_key = ""
    if _tooltip != null:
        _tooltip.hide()


func is_icon_hovered() -> bool:
    return _near and not _hover_key.is_empty()


func diagnostics() -> Dictionary:
    return {"near": _near, "candidate_cells": _candidates.size(),
        "cached_cells": _rows.size(), "icons": _hits.size(),
        "last_batch_size": _last_batch_size, "query_count": _query_count,
        "last_query_ms": _last_query_ms, "viewport_scan_cells": _scan_count}
