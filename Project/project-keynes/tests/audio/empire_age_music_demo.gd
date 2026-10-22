extends "res://tests/audio/agrarian_age_music_demo.gd"
## 帝国时代默认入口（共享四大时代 + 时代升级交互式试听台，初始定位在帝国时代）。


func _init() -> void:
	initial_era = &"empire"
	_simulated_pop = 1800
	_last_action = "开局自动从 0.0s「1. 刚进入游戏 · 九天阊阖」引子起播"
