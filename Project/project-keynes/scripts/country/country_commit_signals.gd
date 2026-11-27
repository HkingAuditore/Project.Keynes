extends RefCounted

## Relays committed country reports and research signals through CountryFacade.

static func dispatch_committed_events(host, result: Dictionary, Opcode: Dictionary) -> void:
	# Runtime graph 一次 pulse 可能跨过多个 country slice；此时 report 是
	# 最后一个 slice 的摘要，其 changed_cells 可能已被后续纯研究/税表提交
	# 覆盖为 0。领土事件流才是这个 generation 间隔内是否发生过领土
	# 变更的可靠证据，必须先 poll 再决定是否广播。
	if not host._configured:
		return
	var events: Dictionary = host._world_ext.poll_country_events(host._last_event_id, 512)
	var ids: PackedInt64Array = events.get("event_ids", PackedInt64Array())
	if not ids.is_empty():
		host._last_event_id = int(ids[ids.size() - 1])
	var opcodes: PackedInt32Array = events.get("opcodes", PackedInt32Array())
	var handles: PackedInt64Array = events.get("country_handles", PackedInt64Array())
	var cells: PackedInt32Array = events.get("cells", PackedInt32Array())
	var signal_ids: PackedInt32Array = events.get("signal_ids", PackedInt32Array())
	var sources: PackedInt32Array = events.get("signal_source_kinds", PackedInt32Array())
	var evidence_deltas: PackedInt32Array = events.get("evidence_deltas", PackedInt32Array())
	var territory_cells: Dictionary = {}
	for i in opcodes.size():
		var opcode := int(opcodes[i])
		if opcode == Opcode.CREATE_COUNTRY \
				or opcode == Opcode.TRANSFER_TERRITORY \
				or opcode == Opcode.CLAIM_UNOWNED_TERRITORY \
				or opcode == Opcode.ANNEX_COUNTRY:
			var territory_cell := int(cells[i]) if i < cells.size() else -1
			if territory_cell >= 0:
				territory_cells[territory_cell] = true
		if opcode != Opcode.DISCOVER_COUNTRY_SIGNAL:
			continue
		host.research_signal_discovered.emit({
			"country_handle": int(handles[i]) if i < handles.size() else 0,
			"cell": int(cells[i]) if i < cells.size() else -1,
			"signal": int(signal_ids[i]) if i < signal_ids.size() else -1,
			"source_kind": int(sources[i]) if i < sources.size() else 0,
			"evidence_delta": int(evidence_deltas[i]) if i < evidence_deltas.size() else 1,
		})
	var normalized := result.duplicate(true)
	if not territory_cells.is_empty():
		normalized["changed_cells"] = maxi(
			int(normalized.get("changed_cells", 0)), territory_cells.size())
		normalized["changed_countries"] = maxi(
			int(normalized.get("changed_countries", 0)), 1)
	if int(normalized.get("changed_countries", 0)) <= 0 \
			and int(normalized.get("changed_cells", 0)) <= 0:
		return
	host.country_committed.emit(normalized)


## Worker-side Country commits enter through the same public signal as the
## synchronous facade.  The worker view already carries the committed
## generation and sparse territory count, so this method never polls or reads
## the mutable legacy Country store.
static func dispatch_worker_committed_view(host, view: Dictionary) -> void:
	if not host._configured:
		return
	var normalized := view.duplicate(false)
	normalized["worker_read_view"] = true
	var changed_count := 0
	var changed_raw = normalized.get("changed_cells", 0)
	if changed_raw is PackedInt32Array:
		changed_count = (changed_raw as PackedInt32Array).size()
	else:
		changed_count = int(changed_raw)
	normalized["changed_cells"] = changed_count
	normalized["changed_countries"] = maxi(
		int(normalized.get("changed_countries", 0)),
		1 if changed_count > 0 else 0)
	if int(normalized.get("generation", 0)) <= 0:
		return
	# Research / treasury soft-commits advance generation with dirty_families
	# and zero territory cells. Never drop those — the tech UI otherwise keeps
	# painting the pre-handoff sync store.
	if int(normalized.get("changed_countries", 0)) <= 0 \
			and int(normalized.get("dirty_families", 0)) <= 0 \
			and int(normalized.get("research_watermark", 0)) <= 0:
		return
	host.country_committed.emit(normalized)
