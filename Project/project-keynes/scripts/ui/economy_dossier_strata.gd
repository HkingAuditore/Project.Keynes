extends RefCounted

## Builds the social strata and profession projections.


static func aggregate_strata(professions: Dictionary, table: SocialStrataTable) -> Array:
	if table == null or not bool(professions.get("ok", false)):
		return []
	var count := table.stratum_count()
	var dim_count := int(professions.get("satisfaction_dimension_count", EconomyDossierViewModel.SATISFACTION_DIMENSIONS.size()))
	var need_count := int(professions.get("need_count", 0))
	var rows: Array = []
	for index in range(count):
		var entry := table.stratum(index)
		var dims := PackedFloat32Array()
		dims.resize(dim_count)
		var dims_population := PackedFloat32Array()
		dims_population.resize(dim_count)
		rows.append({"index": index, "id": String(entry.get("id", "")),
			"name": String(entry.get("name", "")), "icon": StringName(entry.get("icon", "")),
			"color": entry.get("color", UITokens.FAMILY_BRASS), "population": 0.0,
			"cohort_count": 0, "funds": 0.0, "income_per_day": 0.0, "expense_per_day": 0.0,
			"tax_per_day": 0.0, "subsidy_per_day": 0.0, "in_kind_per_day": 0.0,
			"employed": 0.0, "unemployed": 0.0, "satisfaction": 0.0, "survival": 0.0,
			"living": 0.0, "living_name": "",
			"dims": dims, "dims_population": dims_population, "professions": [], "need_population": {}})
	var stable_ids = professions.get("profession_stable_ids", PackedStringArray())
	var names = professions.get("profession_display_names", stable_ids)
	var population = professions.get("population", PackedInt64Array())
	var satisfaction = professions.get("satisfaction_q16", PackedInt32Array())
	var survival = professions.get("survival_satisfaction_q16", PackedInt32Array())
	var living = professions.get("living_standard_level_q16", PackedInt32Array())
	var dims_flat = professions.get("satisfaction_dims_q16", PackedInt32Array())
	var dims_people = professions.get("satisfaction_dims_population", PackedInt64Array())
	var worst = professions.get("worst_need_population", PackedInt64Array())
	var need_names = professions.get("need_display_names", professions.get("need_ids", PackedStringArray()))
	for row in range(stable_ids.size()):
		var stable_id := String(stable_ids[row])
		var index := table.stratum_index_for(stable_id)
		if index < 0 or index >= rows.size():
			continue
		var bucket: Dictionary = rows[index]
		var people := EconomyDossierViewModel._at(population, row)
		bucket.population += people
		bucket.cohort_count += int(EconomyDossierViewModel._at(professions.get("cohort_count", []), row))
		bucket.funds += EconomyDossierViewModel._at(professions.get("funds", []), row)
		bucket.income_per_day += EconomyDossierViewModel._at(professions.get("income_per_day", []), row)
		bucket.expense_per_day += EconomyDossierViewModel._at(professions.get("expense_per_day", []), row)
		bucket.tax_per_day += EconomyDossierViewModel._at(professions.get("tax_per_day", []), row)
		bucket.subsidy_per_day += EconomyDossierViewModel._at(professions.get("subsidy_per_day", []), row)
		bucket.in_kind_per_day += EconomyDossierViewModel._at(professions.get("in_kind_income_per_day", []), row)
		bucket.employed += EconomyDossierViewModel._at(professions.get("owner_employed", []), row) \
			+ EconomyDossierViewModel._at(professions.get("employee_employed", []), row)
		bucket.unemployed += EconomyDossierViewModel._at(professions.get("unemployed", []), row)
		bucket.satisfaction += EconomyDossierViewModel._at(satisfaction, row) * people
		bucket.survival += EconomyDossierViewModel._at(survival, row) * people
		bucket.living += EconomyDossierViewModel._at(living, row) * people
		var dims: PackedFloat32Array = bucket.dims
		for d in range(dim_count):
			var value := EconomyDossierViewModel._at(dims_flat, row * dim_count + d)
			if value >= 0.0:
				var applicable_people := EconomyDossierViewModel._at(dims_people, row * dim_count + d) if row * dim_count + d < dims_people.size() else people
				dims[d] += value * applicable_people
				bucket.dims_population[d] += applicable_people
		bucket.dims = dims
		var needs: Dictionary = bucket.need_population
		for n in range(need_count):
			var affected := EconomyDossierViewModel._at(worst, row * need_count + n)
			if affected > 0.0:
				needs[n] = float(needs.get(n, 0.0)) + affected
		var per_capita := EconomyDossierViewModel._per_capita(EconomyDossierViewModel._at(professions.get("income_per_day", []), row), people)
		(bucket.professions as Array).append({"id": stable_id,
			"name": String(names[row]) if row < names.size() else stable_id,
			"population": people, "satisfaction": EconomyDossierViewModel._at(satisfaction, row) / EconomyDossierViewModel.Q16,
			"income_per_capita": per_capita / EconomyDossierViewModel.MONEY_SCALE})
	var total_population := 0.0
	for bucket in rows:
		total_population += float(bucket.population)
	for bucket in rows:
		var people := float(bucket.population)
		bucket.share = people / total_population if total_population > 0.0 else 0.0
		if people > 0.0:
			bucket.satisfaction = float(bucket.satisfaction) / people / EconomyDossierViewModel.Q16
			bucket.survival = float(bucket.survival) / people / EconomyDossierViewModel.Q16
			var dims: PackedFloat32Array = bucket.dims
			for d in range(dims.size()):
				dims[d] = dims[d] / float(bucket.dims_population[d]) / EconomyDossierViewModel.Q16 if bucket.dims_population[d] > 0.0 else -1.0
			bucket.dims = dims
		bucket.income_per_capita = EconomyDossierViewModel._per_capita(float(bucket.income_per_day), people) / EconomyDossierViewModel.MONEY_SCALE
		bucket.expense_per_capita = EconomyDossierViewModel._per_capita(float(bucket.expense_per_day), people) / EconomyDossierViewModel.MONEY_SCALE
		bucket.funds_per_capita = EconomyDossierViewModel._per_capita(float(bucket.funds), people) / EconomyDossierViewModel.MONEY_SCALE
		bucket.living = float(bucket.living) / people / EconomyDossierViewModel.Q16 if people > 0.0 else 0.0
		bucket.living_name = EconomyDossierViewModel.living_name(float(bucket.living)) if people > 0.0 else ""
		# 详情里的职业条按「本阶层内占比」画：分母是阶层人口而不是全国人口，
		# 这一列要回答的是「这个阶层里谁占大头」。
		for profession in bucket.professions:
			profession["share"] = float(profession.population) / people if people > 0.0 else 0.0
		(bucket.professions as Array).sort_custom(
			func(a, b): return float(a.population) > float(b.population))
		var needs: Array = []
		var need_map: Dictionary = bucket.need_population
		for n in need_map:
			needs.append({"index": int(n), "name": String(need_names[int(n)])
				if int(n) < need_names.size() else "需求 %d" % int(n),
				"population": float(need_map[n]),
				"share": float(need_map[n]) / people if people > 0.0 else 0.0})
		needs.sort_custom(func(a, b): return float(a.population) > float(b.population))
		bucket.worst_needs = needs.slice(0, 4)
		bucket.erase("need_population")
	return rows


## 生活档名称：原生给的是 Q16 的 0..6 连续档位，这里只做台阶命名。
static func living_name(level: float) -> String:
	if is_nan(level) or level < 0.0:
		return ""
	return EconomyDossierViewModel.LIVING_STANDARD_NAMES[clampi(roundi(level), 0, EconomyDossierViewModel.LIVING_STANDARD_NAMES.size() - 1)]


## 职业视角：原生 professions 视图逐职业一行，不做任何阶层合并。
## 原生只发布「有 cohort 的职业」，所以这里天然没有零人口行；按人口降序排，
## 与阶层表的默认「人口占比」排序同向，切视角时第一行还是同一批人。
## 每个职业行仍带着它所属的阶层 id / 名称 / 颜色，用来回答「这个职业算什么阶层」。
static func profession_rows(professions: Dictionary, table: SocialStrataTable) -> Array:
	if table == null or not bool(professions.get("ok", false)):
		return []
	var dim_count := int(professions.get("satisfaction_dimension_count",
		EconomyDossierViewModel.SATISFACTION_DIMENSIONS.size()))
	var need_count := int(professions.get("need_count", 0))
	var stable_ids = professions.get("profession_stable_ids", PackedStringArray())
	var names = professions.get("profession_display_names", stable_ids)
	var population = professions.get("population", PackedInt64Array())
	var satisfaction = professions.get("satisfaction_q16", PackedInt32Array())
	var survival = professions.get("survival_satisfaction_q16", PackedInt32Array())
	var living = professions.get("living_standard_level_q16", PackedInt32Array())
	var dims_flat = professions.get("satisfaction_dims_q16", PackedInt32Array())
	var dims_people = professions.get("satisfaction_dims_population", PackedInt64Array())
	var worst = professions.get("worst_need_population", PackedInt64Array())
	var need_names = professions.get("need_display_names",
		professions.get("need_ids", PackedStringArray()))
	var rows: Array = []
	var total_population := 0.0
	for row in range(stable_ids.size()):
		var people := EconomyDossierViewModel._at(population, row)
		if people <= 0.0:
			continue
		var stable_id := String(stable_ids[row])
		var index := table.stratum_index_for(stable_id)
		var entry := table.stratum(index)
		var dims := PackedFloat32Array()
		dims.resize(dim_count)
		var dims_population := PackedFloat32Array()
		dims_population.resize(dim_count)
		for d in range(dim_count):
			var value := EconomyDossierViewModel._at(dims_flat, row * dim_count + d)
			dims[d] = value / EconomyDossierViewModel.Q16 if value >= 0.0 else -1.0
			dims_population[d] = EconomyDossierViewModel._at(dims_people, row * dim_count + d)
		var needs: Array = []
		for n in range(need_count):
			var affected := EconomyDossierViewModel._at(worst, row * need_count + n)
			if affected <= 0.0:
				continue
			needs.append({"index": n,
				"name": String(need_names[n]) if n < need_names.size() else "需求 %d" % n,
				"population": affected, "share": affected / people})
		needs.sort_custom(func(a, b): return float(a.population) > float(b.population))
		total_population += people
		rows.append({
			"id": stable_id, "index": index,
			"name": String(names[row]) if row < names.size() else stable_id,
			"icon": IconCatalog.profession_semantic(stable_id),
			"color": entry.get("color", UITokens.FAMILY_BRASS),
			"stratum_id": String(entry.get("id", "")),
			"stratum_name": String(entry.get("name", "")),
			"population": people,
			"cohort_count": int(EconomyDossierViewModel._at(professions.get("cohort_count", []), row)),
			"cell_count": int(EconomyDossierViewModel._at(professions.get("cell_count", []), row)),
			"funds": EconomyDossierViewModel._at(professions.get("funds", []), row),
			"funds_per_capita": EconomyDossierViewModel._per_capita(EconomyDossierViewModel._at(professions.get("funds", []), row), people) / EconomyDossierViewModel.MONEY_SCALE,
			"income_per_capita": EconomyDossierViewModel._per_capita(EconomyDossierViewModel._at(professions.get("income_per_day", []), row), people) / EconomyDossierViewModel.MONEY_SCALE,
			"expense_per_capita": EconomyDossierViewModel._per_capita(EconomyDossierViewModel._at(professions.get("expense_per_day", []), row), people) / EconomyDossierViewModel.MONEY_SCALE,
			"tax_per_capita": EconomyDossierViewModel._per_capita(EconomyDossierViewModel._at(professions.get("tax_per_day", []), row), people) / EconomyDossierViewModel.MONEY_SCALE,
			"employed": EconomyDossierViewModel._at(professions.get("owner_employed", []), row)
				+ EconomyDossierViewModel._at(professions.get("employee_employed", []), row),
			"unemployed": EconomyDossierViewModel._at(professions.get("unemployed", []), row),
			"satisfaction": EconomyDossierViewModel._at(satisfaction, row) / EconomyDossierViewModel.Q16,
			"survival": EconomyDossierViewModel._at(survival, row) / EconomyDossierViewModel.Q16,
			"living": EconomyDossierViewModel._at(living, row) / EconomyDossierViewModel.Q16,
			"living_name": EconomyDossierViewModel.living_name(EconomyDossierViewModel._at(living, row) / EconomyDossierViewModel.Q16),
			"dims": dims, "dims_population": dims_population,
			"worst_needs": needs.slice(0, 4),
			"professions": [],
		})
	for entry in rows:
		entry["share"] = float(entry.population) / total_population \
			if total_population > 0.0 else 0.0
	rows.sort_custom(func(a, b): return float(a.population) > float(b.population))
	return rows


## 全国 8 维基线：按「该维适用人口」加权，不适用（-1）的维度不进分母。
static func national_dims(rows: Array) -> PackedFloat32Array:
	var national := PackedFloat32Array()
	national.resize(EconomyDossierViewModel.SATISFACTION_DIMENSIONS.size())
	var weight := PackedFloat32Array()
	weight.resize(national.size())
	for row in rows:
		if float(row.population) <= 0.0:
			continue
		for d in range(national.size()):
			if float(row.dims[d]) >= 0.0:
				var applicable := float(row.dims_population[d])
				national[d] += float(row.dims[d]) * applicable
				weight[d] += applicable
	for d in range(national.size()):
		national[d] = national[d] / weight[d] if weight[d] > 0.0 else -1.0
	return national


## 阶层 / 职业两个视角共用一次查询与一份 8 维基线，页面上切视角不会换口径。
static func strata_model(owner: EconomyDossierViewModel, selected_index: int = -1, mode: String = "stratum",
		selected_profession: String = "") -> Dictionary:
	var professions := owner.query("professions")
	if not bool(professions.get("ok", false)):
		return {"ok": false, "reason": EconomyDossierViewModel._reason(professions)}
	var rows := EconomyDossierViewModel.aggregate_strata(professions, owner._strata)
	var profession_list := EconomyDossierViewModel.profession_rows(professions, owner._strata)
	var national := EconomyDossierViewModel.national_dims(rows)
	var model := {"ok": true, "mode": mode, "rows": rows, "professions": profession_list,
		"selected": {}, "selected_index": -1, "selected_id": "",
		"national_dims": national}
	if mode == "profession":
		var picked := EconomyDossierViewModel._pick_profession(profession_list, selected_profession)
		if picked.is_empty():
			return model
		var detail: Dictionary = (picked as Dictionary).duplicate(true)
		detail["cities"] = owner._cities_for(-1, String(detail.id))
		# 同阶层职业：职业视角里的「同业对照」，选中的那一行由页面高亮。
		var stratum_index := int(detail.index)
		detail["professions"] = rows[stratum_index].professions \
			if stratum_index >= 0 and stratum_index < rows.size() else []
		if owner._history != null and owner.scope_cell < 0:
			detail["satisfaction_trend"] = owner._history.profession_series(
				String(detail.id), "satisfaction")
			detail["income_trend"] = owner._history.profession_series(
				String(detail.id), "income_per_capita")
		model["selected"] = detail
		model["selected_id"] = String(detail.id)
		model["selected_index"] = stratum_index
		return model
	var populated: Array = rows.filter(func(r): return float(r.population) > 0.0)
	if populated.is_empty():
		return model
	var index := selected_index
	if index < 0 or index >= rows.size() or float(rows[index].population) <= 0.0:
		index = int(populated[0].index)
	var selected: Dictionary = rows[index]
	selected["cities"] = owner._cities_for(index, "")
	if owner._history != null and owner.scope_cell < 0:
		selected["satisfaction_trend"] = owner._history.stratum_series(index, "satisfaction")
		selected["income_trend"] = owner._history.stratum_series(index, "income_per_capita")
	model["selected"] = selected
	model["selected_index"] = index
	model["selected_id"] = String(selected.id)
	return model



static func _pick_profession(rows: Array, wanted: String) -> Dictionary:
	if rows.is_empty():
		return {}
	if not wanted.is_empty():
		for row in rows:
			if String(row.id) == wanted:
				return row
	return rows[0]


## 地域分布：stratum_index >= 0 时按阶层归并，否则只看 profession_id 这一个职业。
## 两者读同一份按格职业 CSR（settlements 视图），所以阶层分布加起来就是职业分布。
static func _cities_for(owner: EconomyDossierViewModel, stratum_index: int, profession_id: String) -> Array:
	var page := owner.query("settlements")
	if not bool(page.get("ok", false)) or owner._strata == null:
		return []
	var professions := PackedStringArray()
	if owner._facade != null and owner._facade.has_method("profession_ids"):
		professions = owner._facade.profession_ids()
	var profession_match := -1
	if not profession_id.is_empty():
		profession_match = professions.find(profession_id)
		if profession_match < 0:
			return []
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	var offsets = page.get("profession_offsets", PackedInt32Array())
	var profession_index = page.get("profession_indices", PackedInt32Array())
	var profession_population = page.get("profession_population", PackedInt64Array())
	var profession_satisfaction = page.get("profession_satisfaction_q16", PackedInt32Array())
	var rows: Array = []
	for row in range(cells.size()):
		if row + 1 >= offsets.size():
			break
		var people := 0.0
		var weighted := 0.0
		for k in range(int(offsets[row]), int(offsets[row + 1])):
			var p := int(profession_index[k])
			if profession_match >= 0:
				if p != profession_match:
					continue
			elif p < 0 or p >= professions.size() \
					or owner._strata.stratum_index_for(String(professions[p])) != stratum_index:
				continue
			var count := EconomyDossierViewModel._at(profession_population, k)
			people += count
			weighted += EconomyDossierViewModel._at(profession_satisfaction, k) * count
		if people > 0.0:
			var name := String(names[row]) if row < names.size() else ""
			rows.append({"cell": int(cells[row]),
				"name": name if not name.is_empty() else "村落 #%d" % int(cells[row]),
				"population": people, "satisfaction": weighted / people / EconomyDossierViewModel.Q16})
	rows.sort_custom(func(a, b): return float(a.population) > float(b.population))
	return rows.slice(0, 6)
