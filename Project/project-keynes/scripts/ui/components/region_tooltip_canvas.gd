extends Control

## 刻意不写 class_name（新脚本未进 global_script_class_cache 时裸类名会编译失败），
## 宿主通过场景挂载并以 Control 引用调用。
## 自绘画布的分区提示：绘制时登记 (矩形, 提示文案)，悬停时按位置返回对应提示。
## 供速览纸笺这类「固定版面、文字截断 + 提示补全」的自绘组件使用，避免为每个
## 读数单独建节点。区域在每次 _draw 前由宿主清空重登记，不做逐帧工作。

var _regions: Array = []


func clear_regions() -> void:
	_regions.clear()


func add_region(rect: Rect2, text: String) -> void:
	if not text.is_empty() and rect.size.x > 0.0 and rect.size.y > 0.0:
		_regions.append([rect, text])


func region_count() -> int:
	return _regions.size()


func tooltip_at(at_position: Vector2) -> String:
	for i in range(_regions.size() - 1, -1, -1):
		var region: Array = _regions[i]
		if (region[0] as Rect2).has_point(at_position):
			return String(region[1])
	return ""


func _get_tooltip(at_position: Vector2) -> String:
	var text := tooltip_at(at_position)
	return text if not text.is_empty() else tooltip_text
