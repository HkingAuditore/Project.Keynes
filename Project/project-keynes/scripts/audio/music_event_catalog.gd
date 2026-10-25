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

	## 大厅 / 主菜单背景音乐。不属于任何时代的轮播池，单独播放。
	&"hall": "event:/Music/Hall/hall",

	## 石器时代交互式配乐组曲（含开局 Intro + 3段常态循环 + Population 人口变体 + CameraZoom 镜头缩放变体）。
	&"stone_age_suite": "event:/Music/StoneAge/Suite",

	## 农耕时代交互式配乐组曲（含开局 Intro + 3段常态循环 + Population 人口变体 + CameraZoom 镜头缩放变体）。
	&"agrarian_age_suite": "event:/Music/AgrarianAge/Suite",

	## 王国时代交互式配乐组曲（含开局 Intro + 6段常态循环变体 + Population 人口变体 + CameraZoom 镜头缩放变体）。
	&"kingdom_age_suite": "event:/Music/KingdomAge/Suite",

	## 帝国时代交互式配乐组曲（含开局 Intro + 6段常态循环变体 + Population 人口变体 + CameraZoom 镜头缩放变体）。
	&"empire_age_suite": "event:/Music/EmpireAge/Suite",
}

## 时代 ID 到交互式配乐组曲 key 的映射
const ERA_SUITES := {
	&"stone": &"stone_age_suite",
	&"agrarian": &"agrarian_age_suite",
	&"kingdom": &"kingdom_age_suite",
	&"empire": &"empire_age_suite",
}

## 一次性过渡：时代升级
const TRANSITION := {
	&"trans_explore_feudal": "event:/Music/Transition/trans_explore_feudal",
	&"trans_explore_castle": "event:/Music/Transition/trans_explore_castle",
	&"trans_explore_imperial": "event:/Music/Transition/trans_explore_imperial",
	&"trans_stone_to_agrarian": "event:/Music/Transition/era_stone_to_agrarian",
	&"trans_agrarian_to_kingdom": "event:/Music/Transition/era_agrarian_to_kingdom",
	&"trans_kingdom_to_empire": "event:/Music/Transition/era_kingdom_to_empire",
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
