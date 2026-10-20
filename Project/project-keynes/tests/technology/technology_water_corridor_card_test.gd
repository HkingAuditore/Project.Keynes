extends SceneTree

# 水域通行是纯运行时能力（content_effects.kind = "runtime"），没有建筑或物资载体。
# 科技详情卡曾经只认 building / good / resource / class / terrain / landform /
# climate / tile 八类，把四条航道效果整条丢掉；而「天文导航」的 modifier_terms 与
# effect_summary 又都是空的——它因此渲染成一张没有任何效果的空卡，玩家无从得知
# 这个科技开放的是浅海航道，只会以为开拓队/商队「就是不能过水」。
# 可研究清单的悬停提示当时只读 effect_summary，同一个科技在那里同样是一片空白；
# 两处现在共用 scripts/ui/components/technology_effect_text.gd。

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const TechnologyDetailCardScript = preload(
	"res://scripts/ui/components/technology_detail_card.gd")
const TechnologyAvailableListScript = preload(
	"res://scripts/ui/components/technology_available_list.gd")
# 新脚本的 class_name 要等编辑器重扫才进全局类表，测试里按路径引用更稳。
const TechnologyEffectTextScript = preload(
	"res://scripts/ui/components/technology_effect_text.gd")

# 与 gdext/src/economy_runtime_catalog.cpp 的 water tech 解析一一对应。
const WATER_EFFECTS := {
	"water.river_transport": "河运与湖泊走廊",
	"water.shallow_sea_transport": "浅海运输走廊",
	"water.far_sea_transport": "远海运输走廊",
	"water.deep_sea_transport": "深海运输走廊",
}

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology water corridor card: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	_expect("catalog exposes public definitions", not definitions.is_empty())
	if definitions.is_empty():
		return
	var card: Control = TechnologyDetailCardScript.new()
	var blank_cards: PackedStringArray = PackedStringArray()
	var water_texts := {}
	for value in definitions:
		var definition: Dictionary = value
		if (definition.get("content_effects", []) as Array).is_empty():
			continue
		var items: Array = card._effect_items(definition)
		if items.is_empty():
			blank_cards.append(String(definition.get("id", "")))
			continue
		for item_value in items:
			var text := String((item_value as Dictionary).get("text", ""))
			for effect_value in definition.get("content_effects", []):
				var effect_id := String((effect_value as Dictionary).get("id", ""))
				if WATER_EFFECTS.has(effect_id) \
						and text.contains(String(WATER_EFFECTS[effect_id])):
					water_texts[effect_id] = text
	_expect("no technology with authored effects renders an empty effect list",
		blank_cards.is_empty())
	if not blank_cards.is_empty():
		print("    blank cards: ", blank_cards)
	for effect_id in WATER_EFFECTS:
		_expect("card lists %s" % effect_id, water_texts.has(effect_id))
		_expect("%s reads as a corridor unlock" % effect_id,
			String(water_texts.get(effect_id, "")).begins_with("开启航道 · "))

	# 天文导航是本次回归的原始案例：除了航道，它没有任何别的效果。
	var celestial: Dictionary = {}
	for value in definitions:
		var definition: Dictionary = value
		if String(definition.get("id", "")) == "tech.celestial_navigation":
			celestial = definition
			break
	_expect("tech.celestial_navigation exists", not celestial.is_empty())
	if not celestial.is_empty():
		_expect("tech.celestial_navigation has no modifier or summary to fall back on",
			(celestial.get("modifier_terms", []) as Array).is_empty()
			and String(celestial.get("effect_summary", "")).strip_edges().is_empty())
		var items: Array = card._effect_items(celestial)
		_expect("tech.celestial_navigation shows the shallow-sea corridor",
			items.size() == 1 and String((items[0] as Dictionary).get("text", "")) \
				== "开启航道 · 浅海运输走廊")
	_expect("detail card defers to the shared effect module",
		TechnologyEffectTextScript.effect_items(celestial) == card._effect_items(celestial))
	card.free()

	_run_shared_summary(definitions, celestial)


## 可研究清单的悬停提示曾经只读 effect_summary，所以同一个科技在列表里和水
## 详情卡里各空白一次。两边现在都走 TechnologyEffectText。
func _run_shared_summary(definitions: Array, celestial: Dictionary) -> void:
	if celestial.is_empty():
		return
	_expect("shared summary falls back to structured effects when the author left it blank",
		TechnologyEffectTextScript.summary_text(celestial) == "开启航道 · 浅海运输走廊")
	var river: Dictionary = {}
	for value in definitions:
		var definition: Dictionary = value
		if String(definition.get("id", "")) == "tech.river_transport":
			river = definition
			break
	_expect("tech.river_transport exists", not river.is_empty())
	if not river.is_empty():
		_expect("an authored effect_summary still wins over the structured lines",
			TechnologyEffectTextScript.summary_text(river) \
				== String(river.get("effect_summary", "")).strip_edges())
	_expect("effect_texts carries at least the corridor line",
		TechnologyEffectTextScript.effect_texts(celestial).has("开启航道 · 浅海运输走廊"))

	var list: Control = TechnologyAvailableListScript.new()
	list._definitions = [celestial]
	list._states = PackedInt32Array([5])
	list._items = [{"index": 0}]
	var tooltip := String(list._tooltip_for(0, "card"))
	list.free()
	_expect("research list tooltip no longer shows a summary-less technology",
		tooltip.contains("开启航道 · 浅海运输走廊")
		and tooltip.contains(String(celestial.get("display_name", ""))))
