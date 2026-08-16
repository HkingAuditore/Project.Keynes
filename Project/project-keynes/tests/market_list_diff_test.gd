extends SceneTree

var _failures: int = 0


func _init() -> void:
	var host := Control.new()
	root.add_child(host)
	var market_list := (load("res://scenes/ui/market_list.tscn") as PackedScene).instantiate() as MarketList
	host.add_child(market_list)

	var rows := _rows("10", "3")
	market_list.set_rows(rows)
	_expect(market_list._row_refs.size() == 2, "创建两条商品行")

	var grain: Dictionary = market_list._row_refs["market_grain"]
	var grain_panel := grain.get("panel") as PanelContainer
	_expect((grain.get("tax_editors", {}) as Dictionary).is_empty(),
		"商品行不再创建右侧税率控件")
	_expect(not grain_panel.has_node("Body/Details") \
		and not grain_panel.has_node("Body/Button/Header/Chevron"),
		"商品行不再包含嵌套展开节点")
	var detail_requests: Array = []
	market_list.details_requested.connect(func(request: Dictionary) -> void:
		detail_requests.append(request))
	(grain.get("button") as Button).pressed.emit()
	_expect(detail_requests.size() == 1 \
		and String((detail_requests[0] as Dictionary).get("kind", "")) == "good",
		"点击商品行直接请求统一详情工作区")

	var node_count := _node_count(market_list)
	market_list.update_rows(rows)
	_expect(_node_count(market_list) == node_count, "重复刷新不重建商品行")

	market_list.update_rows(_rows("12", "4"))
	_expect(_node_count(market_list) == node_count, "差量刷新复用商品行节点")
	_expect((grain.get("stock") as Label).text == "12", "差量刷新更新商品摘要值")

	market_list.update_rows([_rows("12", "4")[0]])
	var iron: Dictionary = market_list._row_refs["market_iron"]
	_expect(not (iron.get("panel") as PanelContainer).visible, "缺失商品行仅隐藏不重建")

	host.free()
	print("=== market_list diff test: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _rows(stock: String, demand: String) -> Array:
	return [
		{
			"id": "market_grain",
			"name": "粮食",
			"stock": stock,
			"price": "£1.00",
			"delta": "+1",
			"risk": "",
			"accent": Color.WHITE,
			"icon": "resource",
			"visible": true,
			"tax_lanes": [{"scope": "item", "kind": "consumption",
				"item_id": "grain", "base": 5, "effective": 5,
				"default_rate": 0, "editable": true}],
			"detail_rows": [
				{"id": "demand", "name": "需求", "value": demand},
				{"id": "supply", "name": "供给", "value": "5"},
			],
		},
		{
			"id": "market_iron",
			"name": "铁",
			"stock": "8",
			"price": "£2.00",
			"delta": "—",
			"risk": "",
			"accent": Color.WHITE,
			"icon": "resource",
			"visible": true,
			"detail_rows": [],
		},
	]


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s" % label)


func _node_count(root_node: Node) -> int:
	var count := 1
	for child in root_node.get_children():
		count += _node_count(child)
	return count
