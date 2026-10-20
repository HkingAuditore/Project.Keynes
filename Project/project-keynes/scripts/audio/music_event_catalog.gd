extends RefCounted
## 马里文明探索音乐的 FMOD 事件表。
##
## 由 `tmp/fmod_mali_test` 的测试工程生成，事件定义见
## `马里音乐FMOD测试方案.md`。换文明只需替换本表。
##
## 命名约定：
##   explore_<era>_<NN>  探索音乐轮播片段，循环播放
##   trans_explore_<era> 时代升级过渡，单次播放
##   sting_<era>         胜利 stinger，单次播放且叠加在音乐上

const BANK_ROOT := "res://assets/audio/banks/Desktop/"

## 循环音乐：探索轮播片段
const MUSIC := {
	&"explore_dark_01": "event:/Music/Era/Explore/explore_dark_01",
	&"explore_dark_02": "event:/Music/Era/Explore/explore_dark_02",
	&"explore_dark_03": "event:/Music/Era/Explore/explore_dark_03",
	&"explore_feudal_01": "event:/Music/Era/Explore/explore_feudal_01",
	&"explore_feudal_02": "event:/Music/Era/Explore/explore_feudal_02",
	&"explore_feudal_03": "event:/Music/Era/Explore/explore_feudal_03",
	&"explore_castle_01": "event:/Music/Era/Explore/explore_castle_01",
	&"explore_castle_02": "event:/Music/Era/Explore/explore_castle_02",
	&"explore_castle_03": "event:/Music/Era/Explore/explore_castle_03",
	&"explore_imperial_01": "event:/Music/Era/Explore/explore_imperial_01",
	&"explore_imperial_02": "event:/Music/Era/Explore/explore_imperial_02",
	&"explore_imperial_03": "event:/Music/Era/Explore/explore_imperial_03",
}

## 一次性过渡：时代升级
const TRANSITION := {
	&"trans_explore_feudal": "event:/Music/Transition/trans_explore_feudal",
	&"trans_explore_castle": "event:/Music/Transition/trans_explore_castle",
	&"trans_explore_imperial": "event:/Music/Transition/trans_explore_imperial",
}

## 一次性 stinger：胜利
const STINGER := {
	&"sting_dark": "event:/Music/Stinger/sting_dark",
	&"sting_feudal": "event:/Music/Stinger/sting_feudal",
	&"sting_castle": "event:/Music/Stinger/sting_castle",
	&"sting_imperial": "event:/Music/Stinger/sting_imperial",
}

## 按时代分组的探索曲，供轮播随机挑选
const EXPLORE_BY_ERA := {
	&"dark": [&"explore_dark_01", &"explore_dark_02", &"explore_dark_03"],
	&"feudal": [&"explore_feudal_01", &"explore_feudal_02", &"explore_feudal_03"],
	&"castle": [&"explore_castle_01", &"explore_castle_02", &"explore_castle_03"],
	&"imperial": [&"explore_imperial_01", &"explore_imperial_02", &"explore_imperial_03"],
}


static func path(key: StringName) -> String:
	return String(MUSIC.get(key, ""))


static func transition_path(key: StringName) -> String:
	return String(TRANSITION.get(key, ""))


static func stinger_path(key: StringName) -> String:
	return String(STINGER.get(key, ""))


static func eras() -> Array:
	return EXPLORE_BY_ERA.keys()


static func tracks_for(era: StringName) -> Array:
	return EXPLORE_BY_ERA.get(era, [])
