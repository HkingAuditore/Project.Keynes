extends "res://tests/audio/agrarian_age_music_demo.gd"
## 石器时代默认入口（共享双时代 + 时代升级交互式试听台，初始定位在石器时代）。


func _init() -> void:
	initial_era = &"stone"
	_simulated_pop = 80
	_last_action = "开局自动从 0.0s「1. 刚进入游戏 · 荒原初醒」引子起播"
