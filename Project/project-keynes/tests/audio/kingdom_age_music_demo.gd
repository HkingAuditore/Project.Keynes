extends "res://tests/audio/agrarian_age_music_demo.gd"
## 王国时代默认入口（共享四大时代 + 时代升级交互式试听台，初始定位在王国时代）。


func _init() -> void:
	initial_era = &"kingdom"
	_simulated_pop = 600
	_last_action = "开局自动从 0.0s「1. 刚进入游戏 · 钟鸣鼎食」引子起播"
