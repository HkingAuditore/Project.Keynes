extends RefCounted

## Applies value-only category patches to existing inspector controls. Node construction and signal receivers stay on InspectorPanel.

static func _apply_category_block_patch(
		controls: Dictionary,
		_set_list_caption: Callable,
		_apply_section_texts: Callable,
		data: Dictionary) -> void:
	var block_id := String(data.get("id", "_root"))
	var notes := controls._note_controls.get(block_id) as InspectorNoteList
	if notes != null and data.has("insights"):
		var insights: Array = data.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var facts := controls._metric_controls.get(block_id) as InspectorFactGrid
	if facts != null and data.has("metrics"):
		var metrics: Array = data.get("metrics", [])
		facts.set_facts(metrics)
		facts.visible = not metrics.is_empty()
	var meters := controls._gauge_controls.get(block_id) as InspectorMeterList
	if meters != null and data.has("gauges"):
		var gauges: Array = data.get("gauges", [])
		meters.set_meters(gauges)
		meters.visible = not gauges.is_empty()
	var caption := controls._list_caption_controls.get(block_id) as InspectorNoteList
	if caption != null and data.has("list_caption"):
		_set_list_caption.call(caption, String(data.get("list_caption", "")))
	var refs: Dictionary = controls._section_refs.get(block_id, {})
	if not refs.is_empty():
		_apply_section_texts.call(refs, data)
	if controls._badge_row != null and data.has("badges"):
		controls._badge_row.update_badges(data.get("badges", []))
	if controls._military_ledger != null and data.has("military_cell"):
		controls._military_ledger.set_model(data.get("military_cell", {}))
	if controls._cohort_list != null and data.has("cohort_rows"):
		controls._cohort_list.update_rows(data.get("cohort_rows", []))
	if controls._family_list != null and data.has("family_rows"):
		controls._family_list.update_rows(data.get("family_rows", []))
	if controls._resource_list != null and data.has("resource_rows"):
		controls._resource_list.update_rows(data.get("resource_rows", []))
	if controls._building_list != null and data.has("building_rows"):
		controls._building_list.update_rows(data.get("building_rows", []))
	if controls._construction_workspace != null and data.has("construction_entry"):
		var entry_data: Dictionary = data.get("construction_entry", {})
		if is_instance_valid(controls._construction_entry_hint):
			var hint := String(entry_data.get("hint", ""))
			controls._construction_entry_hint.text = hint
			controls._construction_entry_hint.visible = not hint.is_empty()
	if controls._market_list != null and data.has("market_rows"):
		controls._market_list.update_rows(data.get("market_rows", []))
	for raw in data.get("charts", []):
		var chart: Dictionary = raw
		var spark := controls._chart_controls.get(String(chart.get("id", ""))) as SparklineChart
		if spark != null:
			spark.set_data(
				String(chart.get("title", "")),
				chart.get("values", []),
				chart.get("accent", UITokens.ACCENT),
				float(chart.get("min_value", NAN)),
				float(chart.get("max_value", NAN)),
				int(chart.get("window_size", 0)),
				String(chart.get("value_text", ""))
			)
