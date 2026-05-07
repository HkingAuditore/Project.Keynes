# main.gd
# 程序入口：生成地图并通过 HexRenderer 显示，提供顶部 UI 控制重新生成
# 控制：
#   右键拖拽 — 平移
#   滚轮     — 缩放
#   F        — 适配视口
#   R        — 用新随机种子重新生成

extends Node2D

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0   # 0 = 随机

@onready var _renderer: HexRenderer = $WorldRoot/HexRenderer
@onready var _camera: MapCamera = $MapCamera
@onready var _info_label: Label = $UI/TopBar/InfoLabel

var _current_map: MapData = null

func _ready() -> void:
	_generate_and_render(initial_seed)

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			_generate_and_render(0)   # 随机种子
		KEY_F:
			_camera.fit_to_viewport()

func _generate_and_render(seed_val: int) -> void:
	var cfg := MapConfig.make(map_width, map_height)
	cfg.num_continents = num_continents
	cfg.sea_level = sea_level
	cfg.river_count = river_count
	cfg.seed = seed_val

	var t0: int = Time.get_ticks_msec()
	var generator := MapGenerator.new()
	var result := generator.generate(cfg, hex_size)
	_current_map = result["map"]
	var world_data: WorldData = result["world_data"]
	var elapsed: int = Time.get_ticks_msec() - t0

	_renderer.hex_size = hex_size
	_renderer.set_map(_current_map, world_data)

	# 设置摄像机边界并居中
	_camera.set_world_bounds(_renderer.get_world_bounds())
	_camera.fit_to_viewport(1.05)

	# 顶部信息
	if _info_label != null:
		var stats := _current_map.terrain_stats()
		_info_label.text = "%dx%d  cells=%d  bake=%dms  [R] regenerate  [F] fit  RMB drag  Wheel zoom" % [
			cfg.width, cfg.height, _current_map.cell_count(), elapsed
		]
		print("=== World baked in %dms ===" % elapsed)
		for t in stats:
			print("  %s: %d" % [TerrainType.terrain_name(t), stats[t]])
