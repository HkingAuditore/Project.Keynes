extends RefCounted


## 主粮折叠的展开状态：档位卡展开出作物选项，作物选项展开出具体做法。
## 只影响本页 rows 的生成，进度与报价仍按真实 type 走。
var _construction_expanded_ranks: Dictionary = {}
var _construction_expanded_crops: Dictionary = {}


func snapshot() -> Dictionary:
	return {
		"ranks": _construction_expanded_ranks,
		"crops": _construction_expanded_crops,
	}


## 切换一个折叠卡的展开状态；返回 false 表示不是折叠动作。
func toggle(action: Dictionary) -> bool:
	var kind := String(action.get("kind", ""))
	var rank := int(action.get("rank", -1))
	if kind == "toggle_rank":
		if _construction_expanded_ranks.has(rank):
			_construction_expanded_ranks.erase(rank)
		else:
			_construction_expanded_ranks[rank] = true
		return true
	if kind == "toggle_crop":
		var key := "%d|%s" % [rank, String(action.get("crop", ""))]
		if _construction_expanded_crops.has(key):
			_construction_expanded_crops.erase(key)
		else:
			_construction_expanded_crops[key] = true
		return true
	return false
