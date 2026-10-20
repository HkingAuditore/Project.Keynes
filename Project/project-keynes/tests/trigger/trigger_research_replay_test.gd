extends SceneTree

# Recovery backfill contract for "achievement completed but the permanent
# Country research signal never arrived".
#
# DCWorldExt::replay_completed_research_signal() re-enqueues the achievement's
# single COUNTRY_COMMAND(opcode 14 / domain 1 / CONSTANT value 4) effect:
#   * only ONE_SHOT definitions with development_metric_id >= 0 are accepted
#   * the event day is backfilled to day-1 so the effect delivers at `day`
#   * payload_i0 packs (signal_index << 32) | cell
#   * a pending replay is not duplicated
#   * after delivery the trigger layer does NOT dedupe again; the Country
#     DISCOVER_SIGNAL command dedupes by (signal, cell), which is asserted by the
#     manual_2 save audit rather than here.

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")

const METRIC_ID := "development.employment.agriculture.10_90d"
const EVENT_COUNTRY_DEVELOPMENT_METRIC := 17
const PAYLOAD_COUNTRY_DEVELOPMENT_V1 := 10
const SOURCE_NATIVE := 1
const COUNTRY_COMMAND := 10
const COUNTRY_DOMAIN := 1
const COMMAND_DISCOVER_COUNTRY_SIGNAL := 14
const SOURCE_KIND_TRIGGER_OUTPUT := 4
const REPLAY_DAY := 10
const REPLAY_CELL := 42

var _failures := 0

func _require(value: bool, message: String) -> void:
	if not value:
		_failures += 1
		push_error(message)

func _init() -> void:
	var trigger_catalog: Resource = TriggerCatalogScript.load_default()
	_require(trigger_catalog != null, "default trigger catalog")
	var compiled: Dictionary = trigger_catalog.compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "trigger catalog compile: %s" % str(compiled))
	var trigger_keys: PackedStringArray = compiled.trigger_keys
	var trigger_key := "development.achievement.%s" % METRIC_ID.trim_prefix("development.")
	var trigger_id := trigger_keys.find(trigger_key)
	_require(trigger_id >= 0, "achievement trigger missing: %s" % trigger_key)

	var signal_ids: PackedStringArray = ResearchSignalCatalog.compile_native_catalog().research_signal_ids
	var metrics: Dictionary = DevelopmentAchievementCatalog.compile_native_catalog(signal_ids)
	var metric_ids: PackedStringArray = metrics.development_metric_ids
	var metric := metric_ids.find(METRIC_ID)
	_require(metric >= 0, "development metric missing: %s" % METRIC_ID)
	var signal_index := int(metrics.development_metric_signal_indices[metric])
	var duration_days := int(metrics.development_metric_duration_days[metric])
	var qualifier := int(metrics.development_metric_qualifier_thresholds[metric])
	var target := (1 << 32) | 7 # packed country handle: generation 1, slot 7
	var unknown_target := (1 << 32) | 8

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_require(ext != null, "DCWorldExt unavailable")
	_require(bool(ext.configure_triggers(compiled).get("ok", false)), "trigger configure")

	# Complete the achievement so the facade holds a completed ONE_SHOT state.
	var submitted: Dictionary = ext.submit_trigger_events({
		"event_ids": PackedInt64Array([1]),
		"source_ids": PackedInt32Array([SOURCE_NATIVE]),
		"days": PackedInt64Array([0]),
		"event_types": PackedInt32Array([EVENT_COUNTRY_DEVELOPMENT_METRIC]),
		"payload_schemas": PackedInt32Array([PAYLOAD_COUNTRY_DEVELOPMENT_V1]),
		"entity_handles": PackedInt64Array([target]),
		"group_handles": PackedInt64Array([REPLAY_CELL]),
		"values": PackedInt64Array([qualifier + 1000000]),
		"payload_i0": PackedInt64Array([metric]),
		"payload_i1": PackedInt64Array([duration_days]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	})
	_require(bool(submitted.get("ok", false)), "development metric ingest: %s" % str(submitted))
	_require(bool(ext.run_trigger_daily(0).get("ok", false)), "trigger daily")

	# The completion itself emits the signal effect; simulate the lost delivery by
	# acknowledging it without a Country dispatch.
	var natural: Dictionary = ext.poll_trigger_effects(0, 8)
	var natural_ids: PackedInt64Array = natural.get("effect_ids", PackedInt64Array())
	_require(int(natural.get("count", 0)) == 1 and natural_ids.size() == 1,
		"achievement completion must emit exactly one effect, got %s" % str(natural))
	var natural_actions: PackedInt32Array = natural.get("actions", PackedInt32Array())
	var natural_opcodes: PackedInt32Array = natural.get("opcodes", PackedInt32Array())
	var natural_domains: PackedInt32Array = natural.get("domains", PackedInt32Array())
	_require(int(natural_actions[0]) == COUNTRY_COMMAND and int(natural_opcodes[0]) == COMMAND_DISCOVER_COUNTRY_SIGNAL
		and int(natural_domains[0]) == COUNTRY_DOMAIN, "completion effect shape: %s" % str(natural))
	ext.ack_trigger_effect_ids(natural_ids)
	_require(int(ext.poll_trigger_effects(0, 8).get("count", 0)) == 0,
		"lost effect must be cleared before replay")

	# --- replay enqueues the backfilled signal effect ----------------------
	var replay: Dictionary = ext.replay_completed_research_signal(
		trigger_id, target, REPLAY_CELL, REPLAY_DAY)
	_require(bool(replay.get("ok", false)), "replay: %s" % str(replay))
	_require(bool(replay.get("enqueued", false)), "replay must enqueue: %s" % str(replay))
	var replayed: Dictionary = ext.poll_trigger_effects(0, 8)
	var replayed_ids: PackedInt64Array = replayed.get("effect_ids", PackedInt64Array())
	_require(int(replayed.get("count", 0)) == 1 and replayed_ids.size() == 1,
		"replay must leave exactly one pending effect, got %s" % str(replayed))
	var actions: PackedInt32Array = replayed.get("actions", PackedInt32Array())
	var domains: PackedInt32Array = replayed.get("domains", PackedInt32Array())
	var opcodes: PackedInt32Array = replayed.get("opcodes", PackedInt32Array())
	var days: PackedInt64Array = replayed.get("effective_days", PackedInt64Array())
	var targets: PackedInt64Array = replayed.get("target_handles", PackedInt64Array())
	var trigger_ids: PackedInt32Array = replayed.get("trigger_ids", PackedInt32Array())
	var values: PackedInt64Array = replayed.get("resolved_values", PackedInt64Array())
	var payload: PackedInt64Array = replayed.get("payload_i0", PackedInt64Array())
	_require(int(actions[0]) == COUNTRY_COMMAND, "replay action: %s" % str(actions))
	_require(int(opcodes[0]) == COMMAND_DISCOVER_COUNTRY_SIGNAL, "replay opcode: %s" % str(opcodes))
	_require(int(domains[0]) == COUNTRY_DOMAIN, "replay domain: %s" % str(domains))
	_require(int(days[0]) == REPLAY_DAY, "replay effective day must be %d, got %s"
		% [REPLAY_DAY, str(days)])
	_require(int(targets[0]) == target, "replay target: %s" % str(targets))
	_require(int(trigger_ids[0]) == trigger_id, "replay trigger id: %s" % str(trigger_ids))
	_require(int(values[0]) == SOURCE_KIND_TRIGGER_OUTPUT, "replay constant value: %s" % str(values))
	var packed := (signal_index << 32) | REPLAY_CELL
	_require(int(payload[0]) == packed,
		"replay payload must pack signal %d + cell %d, got %s"
		% [signal_index, REPLAY_CELL, str(payload)])

	# --- pending replay is not duplicated ----------------------------------
	var replay_again: Dictionary = ext.replay_completed_research_signal(
		trigger_id, target, REPLAY_CELL, REPLAY_DAY)
	_require(bool(replay_again.get("ok", false)), str(replay_again))
	_require(not bool(replay_again.get("enqueued", true)),
		"pending replay must not duplicate: %s" % str(replay_again))
	_require(int(ext.poll_trigger_effects(0, 8).get("count", 0)) == 1,
		"pending replay duplicated the effect")

	# --- unknown completed state is a no-op --------------------------------
	var unknown: Dictionary = ext.replay_completed_research_signal(
		trigger_id, unknown_target, REPLAY_CELL, REPLAY_DAY)
	_require(bool(unknown.get("ok", false)), str(unknown))
	_require(not bool(unknown.get("enqueued", true)),
		"no completed state -> nothing to replay: %s" % str(unknown))

	# --- invalid / non-achievement replays are rejected --------------------
	var invalid: Dictionary = ext.replay_completed_research_signal(-1, target, REPLAY_CELL, REPLAY_DAY)
	_require(not bool(invalid.get("ok", false))
		and String(invalid.get("reason", "")) == "trigger_research_replay_invalid", str(invalid))
	var invalid_day: Dictionary = ext.replay_completed_research_signal(
		trigger_id, target, REPLAY_CELL, 0)
	_require(not bool(invalid_day.get("ok", false))
		and String(invalid_day.get("reason", "")) == "trigger_research_replay_invalid", str(invalid_day))
	var non_achievement := -1
	for index in trigger_keys.size():
		if not trigger_keys[index].begins_with("development.achievement."):
			non_achievement = index
			break
	_require(non_achievement >= 0, "no non-achievement trigger found")
	var rejected: Dictionary = ext.replay_completed_research_signal(
		non_achievement, target, REPLAY_CELL, REPLAY_DAY)
	_require(not bool(rejected.get("ok", false))
		and String(rejected.get("reason", "")) == "trigger_research_replay_not_achievement",
		str(rejected))

	# --- after delivery the trigger layer may enqueue again ---------------
	# Country-side (signal, cell) dedupe is the idempotence boundary; the
	# manual_2 audit asserts evidence count does not grow on a second replay.
	ext.ack_trigger_effect_ids(replayed_ids)
	var after_delivery: Dictionary = ext.replay_completed_research_signal(
		trigger_id, target, REPLAY_CELL, REPLAY_DAY)
	_require(bool(after_delivery.get("ok", false)), str(after_delivery))
	_require(bool(after_delivery.get("enqueued", false)),
		"trigger-layer replay after delivery re-enqueues; Country dedupes: %s" % str(after_delivery))

	print("trigger_research_replay_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)
