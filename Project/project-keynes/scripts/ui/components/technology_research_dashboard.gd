extends RefCounted

## Builds the current schedule, queue, and research summary.


static func _sample_history(owner: TechnologyWorkspace) -> void:
	var day := int(owner._research.get("last_research_day", owner._current_day))
	if day < 0:
		day = owner._current_day
	if day < 0:
		return
	var sample := {
		"day": day,
		"stock": int(owner._research.get("technology_points_stock", 0)),
		"progress": int(owner._research.get("progress_total", 0)),
		"cash": int(owner._research.get("country_cash", 0)),
		"purchased": int(owner._research.get("purchased_total", 0)),
	}
	if not owner._history.is_empty():
		var last_day := int((owner._history[owner._history.size() - 1] as Dictionary).day)
		if day < last_day:
			owner._history.clear()
		elif day == last_day:
			owner._history[owner._history.size() - 1] = sample
			return
	owner._history.append(sample)
	while owner._history.size() > TechnologyWorkspace.HISTORY_DAYS:
		owner._history.pop_front()


## Scaled research points invested per day over the recent window, or -1 when
## fewer than two research days have been observed.
static func _daily_research_rate(owner: TechnologyWorkspace) -> float:
	if owner._history.size() < 2:
		return -1.0
	var first: Dictionary = owner._history[maxi(0, owner._history.size() - 8)]
	var last: Dictionary = owner._history[owner._history.size() - 1]
	var days := int(last.day) - int(first.day)
	if days <= 0:
		return -1.0
	return maxf(0.0, float(int(last.progress) - int(first.progress)) / float(days))



static func _history_series(owner: TechnologyWorkspace, key: String, scale: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for sample in owner._history:
		out.append(float((sample as Dictionary).get(key, 0)) / scale)
	return out



static func _daily_progress_series(owner: TechnologyWorkspace) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for cursor in range(1, owner._history.size()):
		var previous: Dictionary = owner._history[cursor - 1]
		var current: Dictionary = owner._history[cursor]
		var days := maxi(1, int(current.day) - int(previous.day))
		out.append(maxf(0.0, float(int(current.progress) - int(previous.progress)))
			/ float(days) / TechnologyWorkspace.POINT_SCALE)
	return out



static func _history_delta(owner: TechnologyWorkspace, key: String, scale: float) -> float:
	if owner._history.size() < 2:
		return NAN
	return float(int((owner._history[owner._history.size() - 1] as Dictionary).get(key, 0))
		- int((owner._history[owner._history.size() - 2] as Dictionary).get(key, 0))) / scale


# Queue order and ETA per queued technology. Overflow moves to the next item of
# the same domain, and empty domains hand their share to non-empty ones, so an
# item finishes once the domain's share has paid for everything ahead of it.
static func _patch_schedule(owner: TechnologyWorkspace, states: PackedInt32Array, progress: PackedInt64Array,
		weights: PackedInt32Array, offsets: PackedInt32Array,
		technologies: PackedInt32Array) -> void:
	var order := {}
	var eta := {}
	var counts := PackedInt32Array([0, 0, 0, 0])
	var rate := owner._daily_research_rate()
	var active_weight := 0
	if offsets.size() >= TechnologyWorkspace.DOMAIN_COUNT + 1:
		for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
			var position := 0
			for cursor in range(offsets[domain], offsets[domain + 1]):
				if cursor < 0 or cursor >= technologies.size():
					continue
				var technology := int(technologies[cursor])
				if technology < 0 or technology >= states.size() or int(states[technology]) >= 4:
					continue
				order[technology] = position
				position += 1
			counts[domain] = position
			if position > 0 and domain < weights.size():
				active_weight += int(weights[domain])
		for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
			if counts[domain] == 0:
				continue
			var share := float(weights[domain]) / float(active_weight) \
				if active_weight > 0 and domain < weights.size() else 0.0
			var domain_rate := rate * share
			var owed := 0.0
			for cursor in range(offsets[domain], offsets[domain + 1]):
				if cursor < 0 or cursor >= technologies.size():
					continue
				var technology := int(technologies[cursor])
				if not order.has(technology):
					continue
				var definition: Dictionary = owner._definitions[technology]
				var cost := maxf(1.0, float(definition.get("cost_points_scaled",
					int(definition.get("cost_points", 1)) * TechnologyWorkspace.POINT_SCALE)))
				var earned := float(progress[technology]) if technology < progress.size() else 0.0
				owed += maxf(0.0, cost - earned)
				if rate < 0.0:
					eta[technology] = ""
				elif domain_rate <= 0.0:
					eta[technology] = ""
				else:
					var days := int(ceil(owed / domain_rate))
					eta[technology] = "约 %d 日" % days if days <= 999 else "超过 999 日"
	owner._queue_order = order
	owner._queue_eta = eta
	owner._dial.set_queue_counts(counts, TechnologyWorkspace.QUEUE_CAPACITY)
	for domain in range(mini(TechnologyWorkspace.DOMAIN_COUNT, owner._queue_headers.size())):
		((owner._queue_headers[domain] as Dictionary).share as Label).text = \
			"%d / %d" % [counts[domain], TechnologyWorkspace.QUEUE_CAPACITY]
		for row in owner._queue_rows[domain]:
			row.set_eta(String(eta.get(int(row.technology_index), "")))
	owner._available.set_queue_info(order, eta)



static func _schedule_text(owner: TechnologyWorkspace, index: int, state: int) -> String:
	match state:
		3:
			var position := int(owner._queue_order.get(index, -1))
			var eta := String(owner._queue_eta.get(index, ""))
			if position < 0:
				return eta
			return "队列第 %d 位%s" % [position + 1, (" · %s" % eta) if not eta.is_empty() else ""]
		4:
			return "待生效"
		2:
			return "未在队列中"
	return ""



static func _update_kpis(owner: TechnologyWorkspace, states: PackedInt32Array) -> void:
	if owner._kpi_cards.is_empty():
		return
	var completed := 0
	var queued := 0
	var pending := 0
	for index in range(mini(states.size(), owner._research_definition_count \
			if owner._research_definition_count > 0 else states.size())):
		if owner._is_retired(index):
			continue
		var state := int(states[index])
		if state >= 5:
			completed += 1
		elif state == 4:
			pending += 1
		elif state == 3:
			queued += 1
	queued += owner._optimistic_queue.size()
	var stock := float(owner._research.get("technology_points_stock", 0)) / TechnologyWorkspace.POINT_SCALE
	var deferred := float(owner._research.get("deferred_unallocated_points", 0)) / TechnologyWorkspace.POINT_SCALE
	var cash := float(owner._research.get("country_cash", 0)) / TechnologyWorkspace.CASH_SCALE
	var budget := float(owner._daily_research_budget()) / TechnologyWorkspace.CASH_SCALE
	var auto_purchase := bool(owner._research.get("auto_purchase_enabled", false)) and budget > 0.0
	var rate := owner._daily_research_rate()
	var history_day := int((owner._history[owner._history.size() - 1] as Dictionary).day) \
		if not owner._history.is_empty() else -1
	# Each card restyles only when its own inputs move, so a research day touches
	# the two or three cards whose numbers actually changed.
	var era := owner._current_era_label(states)
	if owner._kpi_changed("era", hash([era, completed])):
		(owner._kpi_cards.Era as DossierKpiCard).set_metric({
			"id": "era", "title": "当前时代", "kind": "text", "text": era,
			"caption": "已掌握 %d 项科技" % completed, "icon": &"technology.milestone",
			"tooltip": "按已完成的时代晋升推算；在国家顶栏的时代徽记中晋升。",
		})
	if owner._kpi_changed("stock", hash([stock, deferred, queued == 0, history_day])):
		var stock_caption := "每日全部投入研究"
		if deferred > 0.0:
			stock_caption = "%s 因队列阻塞暂存" % UITokens.format_compact_number_cn(deferred, 1)
		elif queued == 0:
			stock_caption = "队列为空，研究暂停"
		(owner._kpi_cards.Stock as DossierKpiCard).set_metric({
			"id": "stock", "title": "科技值库存", "kind": "count", "value": stock,
			"delta": owner._history_delta("stock", TechnologyWorkspace.POINT_SCALE), "caption": stock_caption,
			"icon": IconCatalog.good_semantic("technology_points"),
			"spark": owner._history_series("stock", TechnologyWorkspace.POINT_SCALE),
		})
	if owner._kpi_changed("output", hash([rate, history_day])):
		var output_caption := "等待第二个研究日" if rate < 0.0 \
			else "近 %d 日均值" % mini(7, owner._history.size() - 1)
		(owner._kpi_cards.Output as DossierKpiCard).set_metric({
			"id": "output", "title": "日研究投入", "kind": "count",
			"value": maxf(0.0, rate) / TechnologyWorkspace.POINT_SCALE if rate >= 0.0 else NAN,
			"caption": output_caption, "icon": &"metric.technology",
			"spark": owner._daily_progress_series(),
			"tooltip": "每个研究日投入各领域队列的科技值（产出与采购合计）。",
		})
	if owner._kpi_changed("queue", hash([queued, pending])):
		(owner._kpi_cards.Queue as DossierKpiCard).set_metric({
			"id": "queue", "title": "在研项目", "kind": "text",
			"text": "%d 项" % queued,
			"caption": ("待生效 %d 项" % pending) if pending > 0 \
				else "每个领域最多 %d 项" % TechnologyWorkspace.QUEUE_CAPACITY,
			"icon": &"technology.state.queued",
		})
	if owner._kpi_changed("treasury", hash([cash, budget, auto_purchase, history_day])):
		(owner._kpi_cards.Treasury as DossierKpiCard).set_metric({
			"id": "treasury", "title": "国库现金", "kind": "money", "value": cash,
			"delta": owner._history_delta("cash", TechnologyWorkspace.CASH_SCALE),
			"caption": ("科技采购 %s/日" % UITokens.format_compact_number_cn(budget, 2)) \
				if auto_purchase else "科技采购已关闭",
			"icon": &"metric.treasury", "spark": owner._history_series("cash", TechnologyWorkspace.CASH_SCALE),
		})



static func _kpi_changed(owner: TechnologyWorkspace, id: String, signature: int) -> bool:
	if owner._kpi_signatures.has(id) and int(owner._kpi_signatures[id]) == signature:
		return false
	owner._kpi_signatures[id] = signature
	return true



static func _development_value_text(owner: TechnologyWorkspace, definition: Dictionary, current: int, qualifier: int,
		consecutive: int, target_days: int) -> String:
	var metric_type := int(definition.get("metric_type", 0))
	var current_text := str(current)
	var target_text := str(qualifier)
	if metric_type == TechnologyWorkspace.DevelopmentAchievementCatalogScript.MetricType.SATISFACTION_Q16:
		current_text = "%d%%" % int(round(float(current) * 100.0 / 65536.0))
		target_text = "%d%%" % int(round(float(qualifier) * 100.0 / 65536.0))
	elif metric_type in [TechnologyWorkspace.DevelopmentAchievementCatalogScript.MetricType.INDUSTRY_OUTPUT,
		TechnologyWorkspace.DevelopmentAchievementCatalogScript.MetricType.TRADE_QUANTITY]:
		current_text = UITokens.format_compact_number_cn(float(current) / 1000.0, 1)
		target_text = UITokens.format_compact_number_cn(float(qualifier) / 1000.0, 1)
	var duration := " · %d/%d日" % [mini(consecutive, target_days), target_days] \
		if target_days > 1 else ""
	return "%s/%s%s" % [current_text, target_text, duration]


# The current era is the deepest era whose milestone the country already holds,
# which never leaks how many eras remain.
static func _current_era_label(owner: TechnologyWorkspace, states: PackedInt32Array) -> String:
	var key := hash(states)
	if key == owner._era_label_key and not owner._current_era_text.is_empty():
		return owner._current_era_text
	owner._era_label_key = key
	owner._current_era_text = owner._scan_era_label(states)
	return owner._current_era_text



static func _scan_era_label(owner: TechnologyWorkspace, states: PackedInt32Array) -> String:
	if owner._eras.is_empty():
		return ""
	var reached := 0
	for index in range(mini(states.size(), owner._definitions.size())):
		var definition: Dictionary = owner._definitions[index]
		# 跨时代普通科技不代表晋升；只有已生效里程碑决定当前时代。
		if states[index] >= 5 and bool(definition.get("is_milestone", false)):
			reached = maxi(reached, owner._era_index(String(definition.get("era_id", ""))))
	return String((owner._eras[reached] as Dictionary).get("display_name", "—"))


## 里程碑 ID → 时代显示名。时代闸只说「要升到哪个时代」，不点名里程碑本身。
static func _era_label_for_milestone(owner: TechnologyWorkspace, milestone_id: String) -> String:
	for era in owner._eras:
		if String((era as Dictionary).get("milestone_id", "")) == milestone_id:
			return String((era as Dictionary).get("display_name", milestone_id))
	return milestone_id



static func _patch_queues(owner: TechnologyWorkspace, states: PackedInt32Array, progress: PackedInt64Array,
		weights: PackedInt32Array, offsets: PackedInt32Array = PackedInt32Array(),
		technologies: PackedInt32Array = PackedInt32Array()) -> void:
	if offsets.is_empty():
		offsets = owner._research.get(
			"queue_offsets", PackedInt32Array([0, 0, 0, 0, 0]))
	if technologies.is_empty():
		technologies = owner._research.get(
			"queue_technology_indices", PackedInt32Array())
	if offsets.size() < TechnologyWorkspace.DOMAIN_COUNT + 1:
		return
	# Include per-tech state so pending/owned heads force a rebuild even when
	# the raw queue indices have not changed yet.
	var signature_parts := PackedStringArray()
	signature_parts.append("%s|%s" % [offsets, technologies])
	for technology in technologies:
		var tech := int(technology)
		var state := int(states[tech]) if tech >= 0 and tech < states.size() else 0
		signature_parts.append("%d:%d" % [tech, state])
	var signature := "|".join(signature_parts)
	if signature != owner._queue_signature:
		owner._queue_signature = signature
		owner._rebuild_queue_rows(offsets, technologies)
	for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
		for row in owner._queue_rows[domain]:
			var index := int(row.technology_index)
			var state := int(states[index]) if index < states.size() else 0
			# Settled nodes belong out of the live queue; keep the row quiet
			# until the next signature rebuild drops them.
			if state >= 4:
				row.visible = false
				continue
			row.visible = true
			var definition: Dictionary = owner._definitions[index]
			var cost := maxf(1.0, float(definition.get("cost_points_scaled",
				int(definition.get("cost_points", 1)) * TechnologyWorkspace.POINT_SCALE)))
			var earned := float(progress[index]) if index < progress.size() else 0.0
			row.update_dynamic(state, earned / cost)



static func _rebuild_queue_rows(owner: TechnologyWorkspace, offsets: PackedInt32Array,
		technologies: PackedInt32Array) -> void:
	var research_states: PackedInt32Array = owner._research.get(
		"technology_states", PackedInt32Array())
	for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
		var zone = owner._queue_zones[domain]
		zone.clear_rows()
		owner._queue_rows[domain] = []
		var visible_count := 0
		if offsets[domain + 1] <= offsets[domain]:
			zone.append_position = 0
			zone.set_empty_hint(true)
			continue
		for position in range(offsets[domain], offsets[domain + 1]):
			if position < 0 or position >= technologies.size():
				continue
			var technology := int(technologies[position])
			if technology < 0 or technology >= owner._definitions.size():
				continue
			var state := int(research_states[technology]) \
				if technology < research_states.size() else 0
			# State 4 = pending adoption, 5 = owned. Neither is "in research".
			if state >= 4:
				continue
			var row = TechnologyWorkspace.TechnologyQueueRowScene.instantiate()
			zone.add_child(row)
			row.setup(technology, domain, visible_count,
				String((owner._definitions[technology] as Dictionary).get("display_name", "")),
				owner._domain_accent(domain))
			row.set_retired(owner._is_retired(technology))
			row.move_requested.connect(owner._move_in_queue)
			row.remove_requested.connect(owner._remove_from_queue)
			row.selected_requested.connect(owner._focus_technology)
			owner._queue_rows[domain].append(row)
			visible_count += 1
		zone.append_position = visible_count
		zone.set_empty_hint(visible_count == 0)
