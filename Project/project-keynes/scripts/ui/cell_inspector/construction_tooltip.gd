extends RefCounted

## hover 详情：先答「它提供什么岗位、吃什么、产什么」，再答成本与卡点。
## 每段独立成行、段名在前；没有数据的段整行不出。

static func _construction_tooltip(host, entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String,
		reason_text: String) -> String:
	var h = host
	var lines = PackedStringArray()
	var job_text = host._Construction_delegate._construction_job_text(host, job_spec)
	if not job_text.is_empty():
		lines.append("岗位：%s" % job_text)
	var inputs = host._Construction_delegate._construction_recipe_side(host,
		host._construction_input_recipe_rows(placement, unlocked_goods))
	if not inputs.is_empty():
		lines.append("投入：%s" % inputs)
	var resource_ids: PackedStringArray = placement.get("resource_ids", PackedStringArray())
	var resource_quantities: PackedInt64Array = placement.get(
		"resource_quantities", PackedInt64Array())
	var resource_modes: PackedInt32Array = placement.get("resource_modes", PackedInt32Array())
	var resources := PackedStringArray()
	for index in range(mini(resource_ids.size(), mini(resource_quantities.size(),
			resource_modes.size()))):
		var resource_name: String = h._resource_display_name(resource_ids[index])
		var quantity: String = h._goods_scaled(resource_quantities[index])
		# 承载需求是每栋的储量门槛，开采量才是每日消耗。
		resources.append("%s 需有 %s" % [resource_name, quantity] if resource_modes[index] == 1
			else "%s %s/日" % [resource_name, quantity])
	if not resources.is_empty():
		lines.append("自然资源：%s" % "、".join(resources))
	var outputs = host._Construction_delegate._construction_recipe_side(host,
		h._construction_recipe_rows(placement, "output_good_ids",
			"output_quantities", "产出"))
	if not outputs.is_empty():
		lines.append("产出：%s" % outputs)
	for raw in materials:
		var material: Dictionary = raw
		var required = int(material.get("required", 0))
		var treasury = int(material.get("treasury", 0))
		var market = int(material.get("market", 0))
		var line = "建材：%s %s（国库 %s" % [
			String(material.get("name", "建材")),
			host._goods_scaled(required), host._goods_scaled(treasury)]
		if market > 0:
			line += " / 市购 %s" % h._goods_scaled(market)
		var unit_price = int(material.get("unit_price", 0))
		if unit_price > 0:
			line += " · 单价 %s" % h._money_text(unit_price)
		lines.append(line + "）")
	if not materials.is_empty():
		lines.append("现金：%s" % h._money_text(int(entry.get("cash_required", 0))))
	for raw in materials:
		var material: Dictionary = raw
		var shortfall = int(material.get("market", 0))
		if shortfall <= 0:
			continue
		var good_id = String(material.get("good_id", ""))
		lines.append("现货：%s 现有 %s / 缺口 %s" % [
			String(material.get("name", "建材")),
			host._goods_scaled(int(local_stock.get(good_id, 0))),
			host._goods_scaled(shortfall)])
	var facts = PackedStringArray()
	if not maturity.is_empty():
		facts.append(maturity)
	if days > 0:
		facts.append("工期 %d 日" % days)
	var score = int(entry.get("score", 0))
	if score != 0:
		facts.append("估算毛利 %s/日" % h._money_text(score))
	if not facts.is_empty():
		lines.append("概况：%s" % " · ".join(facts))
	if not reason_text.is_empty():
		lines.append("不满足：%s" % reason_text)
	return "\n".join(lines)


## 报价按一栋建筑计算，国库供料之后才向本地市场采购。
static func _construction_material_status_rows(host, materials: Array,
		local_stock: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	for raw in materials:
		var material: Dictionary = raw
		var good_id := String(material.get("good_id", ""))
		var required := int(material.get("required", 0))
		var treasury := int(material.get("treasury", 0))
		var market_need := int(material.get("market", 0))
		var market_stock := int(local_stock.get(good_id, 0))
		var missing := maxi(0, required - treasury - market_need)
		if local_stock.has(good_id):
			missing += maxi(0, market_need - market_stock)
		var sources := PackedStringArray()
		if treasury > 0:
			sources.append("国库供料" if treasury == required else "国库 %s" % h._goods_scaled(treasury))
		if market_need > 0:
			sources.append("全部市购" if market_need == required else "需市购 %s" % h._goods_scaled(market_need))
		rows.append({
			"name": String(material.get("name", "建材")),
			"good_id": good_id,
			"icon": String(IconCatalog.good_semantic(good_id)),
			"text": "%s 单位" % h._goods_scaled(required),
			"detail": "，".join(sources),
			"missing": missing > 0,
			"missing_text": h._goods_scaled(missing),
			"market_stock_text": h._goods_scaled(market_stock),
			"market_need_text": h._goods_scaled(market_need),
			"reason": ("市场无货" if market_stock == 0 else "市场库存不足") if missing > 0 else "",
		})
	return rows
