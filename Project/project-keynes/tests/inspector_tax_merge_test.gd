extends SceneTree


class FakeCountryFacade extends RefCounted:
	var owned := true
	var country_handle := 7
	var snapshot_calls := 0

	func cell_summary(_cell_idx: int) -> Dictionary:
		return {"ok": true, "owned": owned, "country_handle": country_handle,
			"country_name": "测试国"}

	func cell_tax_policy_snapshot(_cell_idx: int) -> Dictionary:
		snapshot_calls += 1
		return {
			"ok": true, "country_handle": country_handle, "policy_version": 12,
			"country_default_rates": PackedInt32Array([10, 11, 12, 13, 14]),
			"local_default_rates": PackedInt32Array([20, 21, 22, 23, 24]),
			"has_local_default": PackedByteArray([1, 0, 1, 0, 1]),
			"income": _group(["artisan"], [25], [26], [1], [10]),
			"consumption": _group(["grain"], [31], [32], [1], [11]),
			"business": _group(["forge"], [33], [34], [1], [12]),
			"import": _group(["grain"], [35], [36], [1], [13]),
			"export": _group(["grain"], [37], [38], [1], [14]),
		}

	func report() -> Dictionary:
		return {"last_committed_day": 40}

	func _group(ids: Array, base: Array, effective: Array,
			flags: Array, country_base: Array) -> Dictionary:
		return {
			"item_ids": PackedStringArray(ids),
			"final_base_rates": PackedInt32Array(base),
			"effective_rates": PackedInt32Array(effective),
			"has_local_item": PackedByteArray(flags),
			"country_base_rates": PackedInt32Array(country_base),
		}


class FakeGenerator extends RefCounted:
	var country := FakeCountryFacade.new()

	func get_country_facade():
		return country

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}


func _initialize() -> void:
	var failures := PackedStringArray()
	var view_model := CellInspectorViewModel.new()
	var generator := FakeGenerator.new()
	view_model.set_context(null, generator, null, null, 0.42, 22.0)

	var population := view_model._decorate_category_with_tax(0, "population", {
		"cohort_rows": [{"id": "cohort_1", "profession_id": "artisan"}],
	})
	var market := view_model._decorate_category_with_tax(0, "market", {
		"market_rows": [{"id": "market_1", "good_id": "grain"}],
	})
	var buildings := view_model._decorate_category_with_tax(0, "buildings", {
		"building_rows": [{"id": "building_1", "building_type_id": "forge"}],
	})

	_assert_tax_shape(failures, population, "cohort_rows", 1, 1)
	_assert_tax_shape(failures, market, "market_rows", 3, 3)
	_assert_tax_shape(failures, buildings, "building_rows", 1, 1)
	if generator.country.snapshot_calls != 3:
		failures.append("a merged category read the cell tax snapshot more than once")
	if (population.get("tax_context", {}) as Dictionary).has("policy"):
		failures.append("tax context leaked the facade snapshot into UI data")
	var population_lane: Dictionary = ((population.get("cohort_rows", []) as Array)[0] \
		as Dictionary).get("tax_lanes", [])[0]
	if String(population_lane.get("item_id", "")) != "artisan" \
			or int(population_lane.get("base", -1)) != 25 \
			or int(population_lane.get("effective", -1)) != 26:
		failures.append("income lane did not bind the profession override")

	generator.country.country_handle = 9
	var foreign := view_model._decorate_category_with_tax(0, "population", {
		"cohort_rows": [{"id": "cohort_foreign", "profession_id": "artisan"}],
	})
	if bool((foreign.get("tax_context", {}) as Dictionary).get("editable", true)) \
			or bool((((foreign.get("cohort_rows", []) as Array)[0] as Dictionary) \
				.get("tax_lanes", []) as Array)[0].get("editable", true)):
		failures.append("foreign territory exposed editable merged tax lanes")
	generator.country.owned = false
	var unowned := view_model._decorate_category_with_tax(0, "population", {
		"cohort_rows": [{"id": "cohort_unowned", "profession_id": "artisan"}],
	})
	if bool((unowned.get("tax_context", {}) as Dictionary).get("editable", true)):
		failures.append("unowned territory exposed editable merged tax context")

	var root := Control.new()
	get_root().add_child(root)
	var editor := (load("res://scenes/ui/object_tax_lane.tscn") as PackedScene) \
		.instantiate() as TaxLaneEditor
	root.add_child(editor)
	editor.set_data(population_lane)
	var requests: Array = []
	editor.override_requested.connect(func(scope: String, kind: String,
			item_id: String, rate: int) -> void:
		requests.append([scope, kind, item_id, rate]))
	editor._spin.set_value_no_signal(29)
	editor._on_text_submitted("")
	if requests.size() != 1 or requests[0] != ["item", "income", "artisan", 29]:
		failures.append("tax lane editor did not emit an isolated row override")

	if failures.is_empty():
		print("[inspector-tax-merge] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[inspector-tax-merge] FAIL: %s" % failure)
		quit(1)


func _assert_tax_shape(failures: PackedStringArray, category: Dictionary,
		row_key: String, default_count: int, lane_count: int) -> void:
	var context: Dictionary = category.get("tax_context", {})
	var rows: Array = category.get(row_key, [])
	if not bool(context.get("available", false)) \
			or not bool(context.get("editable", false)) \
			or (context.get("default_lanes", []) as Array).size() != default_count:
		failures.append("%s did not expose the expected page defaults" % row_key)
	elif rows.size() != 1 \
			or ((rows[0] as Dictionary).get("tax_lanes", []) as Array).size() != lane_count:
		failures.append("%s did not expose the expected row tax lanes" % row_key)
