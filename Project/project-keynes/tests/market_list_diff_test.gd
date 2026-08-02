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
	var grain_details := grain.get("details") as VBoxContainer
	_expect(grain_details.get_child_count() == 0, "折叠时不创建详情节点")

	market_list.update_rows(rows)
	_expect(grain_details.get_child_count() == 0, "重复刷新不创建折叠详情")

	market_list.set_expanded("market_grain", true)
	_expect(grain_details.get_child_count() == 2, "展开时按需创建详情节点")
	var detail_count := grain_details.get_child_count()

	market_list.update_rows(_rows("12", "4"))
	_expect(grain_details.get_child_count() == detail_count, "差量刷新复用详情节点")
	var detail_refs: Dictionary = grain.get("detail_refs", {})
	var demand_detail: Dictionary = detail_refs.get("demand", {})
	_expect((demand_detail.get("value") as Label).text == "4", "展开详情更新最新值")

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
