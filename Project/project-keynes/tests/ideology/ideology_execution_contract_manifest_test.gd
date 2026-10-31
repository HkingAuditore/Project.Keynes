extends SceneTree
## Plan 11.5, the WHOLE-PACKAGE half of the execution-contract identity.
##
## WHAT WAS ALREADY TRUE
##
## `cell_program_execution_contract_hash` exists inside the PKID payload. The
## native reader compares the payload's stamp against the runtime's own and
## refuses with `cell_program_execution_contract_mismatch`. That half is pinned by
## `ideology_save_payload_robustness_test` and `ideology_effect_metric_publish_test`.
##
## WHAT WAS MISSING
##
## The identity also has to enter the CONTAINER-level compatibility check.
## `game_save_coordinator.gd` writes one `provider_manifest` entry per provider
## (`provider_id`, `schema_version`, `sections`, `state_hash`) and
## `_manifest_compatible` validates it at load. The ideology contract was not in
## it, so a whole-package load could only discover a contract problem after
## PKCN/PKEF had already been restored -- or not at all, for an archive whose
## PKID payload was empty.
##
## THE THREE VERSION SPACES, NEVER CONFLATED (more than one of them is "2")
##
##   provider-section schema_version : 2   (the pkid manifest entry's own version)
##   PKID payload schema             : 14  (inside the bytes, native reader)
##   execution contract              : a 64-bit HASH of the rule versions plus
##                                     the ideology / Effect / Modifier catalog
##                                     hashes. It can change with no schema bump
##                                     (a catalog edit) and stay equal across a
##                                     bump. Only the third is compared here.
##
## THE DECISION FOR LEGACY ARCHIVES (the backward-honest half)
##
## An archive written before this field existed has NO key in its manifest entry.
## Neither extreme is acceptable:
##   * refusing every such archive would break every save on disk while buying no
##     safety -- the PKID payload already carries the SAME identity and compares
##     it exactly, a few frames later;
##   * recording it as a match would be a lie: nothing verified it.
## So a missing key means UNSTATED, which is a THIRD outcome: the manifest gate
## neither refuses nor certifies. It returns `deferred=true` with
## `detail=contract_unstated`, records that verdict on the prepared bundle, and
## logs it on restore. The refusal plan 11.5 names for old archives
## (`cell_program_execution_contract_mismatch`) is then delivered by the layer
## that owns the identity. An old archive carrying NO ideology state at all is
## accepted outright (`contract_unstated_no_state`): there is no
## contract-governed state to reinterpret, and refusing it would be exactly the
## "refuse an otherwise-compatible archive" mistake.
##
## WHY THE REFUSAL CODE IS NOT THE PAYLOAD CODE
##
## `cell_program_execution_contract_mismatch` is a native verdict reached after
## restore has begun. `cell_program_execution_contract_manifest_mismatch` is the
## GDScript pre-flight that refuses before any provider touches the world. One
## string for both would make the two layers indistinguishable in a log -- and in
## a test, where this file's central assertion could be satisfied by the payload
## reader instead, passing while the new gate did nothing.
##
## WHAT THIS FILE MEASURES
##
##   A. the pkid manifest entry carries the identity, and every OTHER provider's
##      entry stays BYTE-IDENTICAL to the four fixed keys it always wrote;
##   B. the identity is the RUNNING one, and an unconfigured runtime writes no key
##      at all (unstated is not stored as 0);
##   C. the identity survives the PKSV JSON header round trip (it is written as a
##      decimal string, because a 64-bit hash in a JSON NUMBER is only exact
##      while the reader preserves int64 -- measured below, not assumed);
##   D. the whole verdict table, including all three legacy outcomes and the rule
##      that no contract_matches is ever reported without a comparison;
##   E. end to end through the real repository and the real coordinator: a slot is
##      written, the header's stored FORM is read back off the disk, and the slot
##      is listed, prepared and restored, with every refusal carrying the named
##      code. Restore is exercised with deliberately minimal sections, so a gate
##      that stopped firing fails as a clean `save_provider_missing` instead of
##      dereferencing a world this fixture does not build -- which is also how the
##      legacy deferral is proven to reach the providers instead of refusing.
##
## A NOTE ON HOW THIS FILE LOADS THE COORDINATOR. `game_save_coordinator.gd` is an
## autoload that names `GameSettings` / `GameFlow` as bare identifiers, and a `-s`
## script run only registers those globals once the autoloads exist in the tree
## (measured: `_init` sees an empty root and a `preload` of the coordinator fails
## to compile with "Identifier not found: GameSettings"; `_initialize` sees
## GameSettings/GameAudio/GameSave/GameFlow and a deferred `load()` succeeds). The
## fixture therefore runs from `_initialize` and loads the script at runtime
## instead of preloading it, and it instantiates its OWN coordinator in a `user://`
## save directory rather than touching the GameSave autoload's real slots.
##
## Run:
##   <godot> --headless --path Project/project-keynes -s \
##     tests/ideology/ideology_execution_contract_manifest_test.gd

const SAVE_DIR := "user://execution_contract_manifest_fixture"
const SLOT := "manual_1"
## A 60-bit identity: past 2^53, so any double-based path would corrupt it.
const CONTRACT := 1311768467294899695
const OTHER_CONTRACT := 1311768467294899696
const FIXED_KEYS := ["provider_id", "schema_version", "sections", "state_hash"]

var _checks := 0
var _failures := 0
var _script: GDScript = null
var _coordinator: Node = null
var _host: WorldRuntimeHost = null
var _generator: MapGenerator = null
var _facade = null
var _key := ""
var _manifest_code := ""
var _payload_code := ""
var _industry_revision := -1


## The only thing `game_save_coordinator` reads from a live world for plan 11.5
## is `MapGenerator.get_ideology_report()` -> `IdeologyFacade.report()`. Standing
## the real generator's facade slot with this keeps the production code path
## (generator method, report dictionary, no test-only branch in the coordinator)
## while making the contract a value this fixture controls.
class FakeIdeologyFacade:
	extends RefCounted
	var contract := 0

	func report() -> Dictionary:
		return {"configured": contract != 0, "execution_contract_hash": contract}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_script = load("res://scripts/game/game_save_coordinator.gd")
	if _script == null or not _script.can_instantiate():
		_expect("the whole-package coordinator loads", false, str(_script))
		_finish(3)
		return
	var constants: Dictionary = _script.get_script_constant_map()
	_key = String(constants.get("EXECUTION_CONTRACT_KEY", ""))
	_manifest_code = String(constants.get("EXECUTION_CONTRACT_MANIFEST_CODE", ""))
	_payload_code = String(constants.get("EXECUTION_CONTRACT_PAYLOAD_CODE", ""))
	_industry_revision = int(constants.get("TECHNOLOGY_INDUSTRY_REVISION", -1))
	if not _require("the gate's constants exist on the production script",
			not _key.is_empty() and not _manifest_code.is_empty()
				and not _payload_code.is_empty() and _industry_revision > 0,
			"key=%s manifest=%s payload=%s industry=%d"
				% [_key, _manifest_code, _payload_code, _industry_revision]):
		_finish(3)
		return
	OS.set_environment("PK_SAVE_DIR", SAVE_DIR)
	# `_repository` is a field initializer, so the override must be in the
	# environment BEFORE construction. The instance is deliberately NOT added to
	# the tree: `_ready` would connect to GameSettings, and this fixture must not
	# share the GameSave autoload's state.
	_coordinator = _script.new()
	_coordinator._register_providers()
	_generator = MapGenerator.new()
	_facade = FakeIdeologyFacade.new()
	_generator._ideology_facade = _facade
	_host = WorldRuntimeHost.new()
	_host._generator = _generator
	_coordinator._runtime_host = _host

	_test_manifest_shape()
	_test_identity_source()
	_test_json_identity()
	_test_verdict_table()
	_test_package_gate()

	_cleanup()
	_finish(0 if _failures == 0 else 3)


# --- A. the manifest entry ---------------------------------------------------

func _test_manifest_shape() -> void:
	print("")
	print("[11.5] ===== A. the pkid manifest entry carries the identity =====")
	_facade.contract = CONTRACT
	var manifest := _build_manifest()
	var pkid := _manifest_entry(manifest, "pkid")
	_expect("A1 plan 11.5: the pkid manifest entry carries the execution contract",
		pkid.has(_key), str(pkid.keys()))
	_expect("A2 ... and its value is the contract this runtime is running",
		String(pkid.get(_key, "")) == str(CONTRACT), str(pkid.get(_key, "<absent>")))
	var missing: Array = []
	for key in FIXED_KEYS:
		if not pkid.has(key):
			missing.append(key)
	_expect("A3 ... without losing any of the four fixed keys", missing.is_empty(),
		"missing=%s" % str(missing))
	# A4 is byte-identity, not key-count: a provider that declares no identity must
	# write the SAME FOUR KEYS with the same values as before this feature existed.
	# Comparing serialized Variant bytes covers key NAMES, key ORDER and value TYPES
	# in one assertion, so an added empty key, a renamed key or a reordered dict all
	# fail here -- a count alone would let any of them through.
	var offenders: Array = []
	for provider in _coordinator._providers:
		var provider_id := String(provider.provider_id())
		if provider_id == "pkid":
			continue
		var expected := {
			"provider_id": provider_id,
			"schema_version": int(provider.schema_version()),
			"sections": Array(provider.section_ids()),
			"state_hash": "",
		}
		var actual: Dictionary = provider.manifest_entry({"generator": _generator}, false)
		if var_to_bytes(actual) != var_to_bytes(expected):
			offenders.append("%s wrote %s" % [provider_id, str(actual)])
	_expect("A4 every OTHER provider writes a byte-identical four-key entry (a "
		+ "provider that declares no identity cannot gain, lose or reorder a key)",
		offenders.is_empty(), str(offenders))
	var with_hash: Dictionary = _provider("pkid").manifest_entry(
		{"generator": _generator}, true)
	_expect("A5 the identity is written whether or not the state hash is",
		with_hash.has(_key)
			and not String(with_hash.get("state_hash", "")).is_empty(),
		"keys=%s" % str(with_hash.keys()))


# --- B. where the identity comes from ---------------------------------------

func _test_identity_source() -> void:
	print("")
	print("[11.5] ===== B. the identity is the RUNNING contract =====")
	_facade.contract = OTHER_CONTRACT
	var other := _manifest_entry(_build_manifest(), "pkid")
	_expect("B1 a runtime under a different contract writes a different identity "
		+ "(the value is read, not hard-coded)",
		String(other.get(_key, "")) == str(OTHER_CONTRACT), str(other.get(_key, "<absent>")))
	_facade.contract = 0
	var unconfigured := _manifest_entry(_build_manifest(), "pkid")
	_expect("B2 a runtime that cannot state its contract writes NO key (unstated is "
		+ "not stored as 0, which would look like a stored identity)",
		not unconfigured.has(_key), str(unconfigured.keys()))
	_facade.contract = 0x7FFFFFFFFFFFFFFF
	var extreme := _manifest_entry(_build_manifest(), "pkid")
	_expect("B3 a maximal 64-bit contract is written without being clamped or rounded",
		String(extreme.get(_key, "")) == str(0x7FFFFFFFFFFFFFFF),
		str(extreme.get(_key, "<absent>")))
	_facade.contract = CONTRACT


# --- C. the identity survives the PKSV header --------------------------------

func _test_json_identity() -> void:
	print("")
	print("[11.5] ===== C. the identity survives the PKSV JSON header =====")
	var exact := true
	for value in [0x7FFFFFFFFFFFFFFF, -0x7FFFFFFFFFFFFFFF, CONTRACT, -CONTRACT]:
		var payload := {}
		payload[_key] = str(value)
		var text := JSON.stringify(payload)
		var back = JSON.parse_string(text)
		var got: int = _coordinator._contract_value(back.get(_key, 0))
		if got != value:
			exact = false
			print("[11.5] C: round trip lost %d -> %d (%s)" % [value, got, text])
	_expect("C1 every 64-bit identity round-trips through JSON exactly, because the "
		+ "manifest stores a decimal string", exact)
	# MEASURED, so the choice above is evidence and not taste. A JSON NUMBER is a
	# double by spec; this prints what THIS parser does with one past 2^53.
	var numeric_payload := {}
	numeric_payload[_key] = CONTRACT
	var numeric_text := JSON.stringify(numeric_payload)
	var numeric_back = JSON.parse_string(numeric_text)
	var numeric_value = numeric_back.get(_key, 0)
	print("[11.5] C: JSON NUMBER %s -> %s (%s)"
		% [numeric_text, str(numeric_value), type_string(typeof(numeric_value))])
	# A manifest written by a foreign writer with a NUMBER still compares --
	# normalization accepts int / float / decimal string. (What it must NOT do is
	# WRITE one: the print above shows this parser handing a 60-bit value back as
	# a float with its low bits changed, which is exactly why the manifest stores
	# the identity as a decimal string.)
	var foreign_entry := {
		"provider_id": "pkid", "schema_version": 2, "sections": ["pkid"],
		"state_hash": "",
	}
	foreign_entry[_key] = CONTRACT
	var foreign: Array = [foreign_entry]
	var foreign_verdict: Dictionary = _coordinator._execution_contract_verdict(
		foreign, CONTRACT, true)
	_expect("C2 an in-memory numeric identity from a foreign writer compares as a match",
		bool(foreign_verdict.get("ok", false))
			and String(foreign_verdict.get("detail", "")) == "contract_matches",
		str(foreign_verdict))
	_expect("C3 an unreadable identity normalizes to 0 (unknown), never to a number",
		_coordinator._contract_value({"not": "a value"}) == 0
			and _coordinator._contract_value(null) == 0
			and _coordinator._contract_value("not_a_number") == 0)


# --- D. the verdict table ----------------------------------------------------

func _test_verdict_table() -> void:
	print("")
	print("[11.5] ===== D. the whole-package verdict =====")
	var matching := _stamped(str(CONTRACT))
	var differing := _stamped(str(OTHER_CONTRACT))
	var unstated: Array = [{"provider_id": "pkid", "schema_version": 2,
		"sections": ["pkid"], "state_hash": ""}]
	var zero_stamp := _stamped("0")

	var match_verdict: Dictionary = _coordinator._execution_contract_verdict(
		matching, CONTRACT, true)
	_expect("D1 a certified matching contract passes and says it was VERIFIED",
		bool(match_verdict.get("ok", false))
			and String(match_verdict.get("detail", "")) == "contract_matches"
			and not bool(match_verdict.get("deferred", true))
			and String(match_verdict.get("code", "x")).is_empty(),
		str(match_verdict))

	var differ_verdict: Dictionary = _coordinator._execution_contract_verdict(
		differing, CONTRACT, true)
	_expect("D2 a certified DIFFERENT contract is refused with the named code",
		not bool(differ_verdict.get("ok", true))
			and String(differ_verdict.get("code", "")) == _manifest_code
			and String(differ_verdict.get("detail", "")) == "contract_differs",
		str(differ_verdict))
	_expect("D3 ... and the message names both identities, so a log is diagnosable",
		String(differ_verdict.get("message", "")).contains(str(CONTRACT))
			and String(differ_verdict.get("message", "")).contains(str(OTHER_CONTRACT)),
		String(differ_verdict.get("message", "")))

	var unstamped_state: Dictionary = _coordinator._execution_contract_verdict(
		unstated, CONTRACT, true)
	_expect("D4 a pre-field archive WITH ideology state is not refused and not "
		+ "claimed as verified: it defers to the payload",
		bool(unstamped_state.get("ok", false))
			and bool(unstamped_state.get("deferred", false))
			and String(unstamped_state.get("detail", "")) == "contract_unstated",
		str(unstamped_state))
	_expect("D5 ... and its message names the payload code that owns the refusal "
		+ "(plan 11.5: an old archive refuses with cell_program_execution_contract_mismatch)",
		String(unstamped_state.get("message", "")).contains(_payload_code),
		String(unstamped_state.get("message", "")))

	var unstamped_empty: Dictionary = _coordinator._execution_contract_verdict(
		unstated, CONTRACT, false)
	_expect("D6 a pre-field archive with NO ideology state is accepted outright: "
		+ "there is nothing a contract could reinterpret",
		bool(unstamped_empty.get("ok", false))
			and not bool(unstamped_empty.get("deferred", true))
			and String(unstamped_empty.get("detail", "")) == "contract_unstated_no_state",
		str(unstamped_empty))

	var zero_verdict: Dictionary = _coordinator._execution_contract_verdict(
		zero_stamp, CONTRACT, true)
	_expect("D7 a stored identity of 0 means UNSTATED, never a match",
		bool(zero_verdict.get("ok", false))
			and String(zero_verdict.get("detail", "")) == "contract_unstated"
			and bool(zero_verdict.get("deferred", false)),
		str(zero_verdict))

	var blind: Dictionary = _coordinator._execution_contract_verdict(
		differing, 0, true)
	_expect("D8 with no running runtime (the session request runs before a world "
		+ "exists) the gate must NOT refuse: it defers",
		bool(blind.get("ok", false))
			and bool(blind.get("deferred", false))
			and String(blind.get("detail", "")) == "contract_unverifiable",
		str(blind))

	var no_provider: Dictionary = _coordinator._execution_contract_verdict(
		[{"provider_id": "technology_industry", "schema_version": 2,
			"sections": [], "content_hash": ""}], CONTRACT, true)
	_expect("D9 an archive from before the ideology provider is accepted",
		bool(no_provider.get("ok", false))
			and String(no_provider.get("detail", "")) == "contract_no_provider",
		str(no_provider))
	var null_manifest: Dictionary = _coordinator._execution_contract_verdict(
		null, CONTRACT, true)
	_expect("D10 a non-manifest never crashes the gate",
		not null_manifest.is_empty(), str(null_manifest))

	_expect("D11 the manifest refusal has its OWN identity, in the same greppable "
		+ "family as the payload refusal",
		_manifest_code != _payload_code
			and _manifest_code.begins_with("cell_program_execution_contract_")
			and _payload_code.begins_with("cell_program_execution_contract_"),
		"%s vs %s" % [_manifest_code, _payload_code])

	# D8 covers a DIFFERING stamp read by a runtime that cannot state its contract.
	# This is the harder case for the "never report a match without a comparison"
	# rule: the stored value LOOKS right, and only the missing running identity
	# stops the gate from certifying it.
	var blind_match: Dictionary = _coordinator._execution_contract_verdict(
		matching, 0, true)
	_expect("D12 a stamp that would match still defers when the running contract is "
		+ "unknown: no comparison happened, so there is no contract_matches",
		bool(blind_match.get("ok", false))
			and bool(blind_match.get("deferred", false))
			and String(blind_match.get("detail", "")) == "contract_unverifiable"
			and not (String(blind_match.get("detail", "")) == "contract_matches"),
		str(blind_match))


# --- E. end to end through the real repository -------------------------------

func _test_package_gate() -> void:
	print("")
	print("[11.5] ===== E. the whole-package load gate =====")
	_facade.contract = CONTRACT
	var written: Dictionary = _write_slot(_build_manifest(), PackedByteArray([1, 2, 3, 4]))
	if not _require("E1 a PKSV slot carrying the identity writes",
			bool(written.get("ok", false)), str(written)):
		return

	# The decimal-string decision, asserted at the layer that WRITES it. C1 proves
	# the format survives a JSON round trip; this reads the header bytes the
	# repository itself just wrote to disk and requires the identity to be QUOTED.
	# An int-encoded identity would be corrupted by its own header -- measured in C,
	# where this parser turns the same number into 1311768467294899712.0 -- and
	# would then refuse every save it wrote.
	var header_text := _header_text()
	var key_at := header_text.find("\"%s\"" % _key)
	var stored_form := "identity absent from the header"
	if key_at >= 0:
		stored_form = header_text.substr(key_at, 64)
	_expect("E1a the PKSV header on disk stores the identity as a quoted DECIMAL "
		+ "STRING, never as a JSON number",
		header_text.contains("\"%s\":\"%d\"" % [_key, CONTRACT])
			and not header_text.contains("\"%s\":%d" % [_key, CONTRACT]),
		stored_form)

	var prepared: Dictionary = _coordinator.prepare_load(SLOT)
	if not _require("E2 prepare_load accepts a matching contract",
			bool(prepared.get("ok", false)), str(prepared)):
		return
	var bundle: Dictionary = prepared.get("bundle", {})
	var recorded: Dictionary = bundle.get("execution_contract", {})
	_expect("E3 ... and RECORDS that the identity was verified (not merely not refused)",
		String(recorded.get("detail", "")) == "contract_matches"
			and not bool(recorded.get("deferred", true)),
		str(recorded))

	var slot := _slot(_coordinator.list_slots(), SLOT)
	_expect("E4 the pause-menu slot list keeps it loadable",
		bool(slot.get("loadable", false)), str(slot.get("reason", "")))

	_facade.contract = OTHER_CONTRACT
	slot = _slot(_coordinator.list_slots(), SLOT)
	_expect("E5 the pause-menu slot list greys out a slot whose contract differs and "
		+ "names the code in the tooltip",
		not bool(slot.get("loadable", true))
			and String(slot.get("reason", "")).contains(_manifest_code),
		str(slot.get("reason", "")))
	var refused: Dictionary = _coordinator.prepare_load(SLOT)
	_expect("E6 prepare_load refuses it with the named code",
		not bool(refused.get("ok", true))
			and String(refused.get("code", "")) == _manifest_code,
		str(refused))

	_facade.contract = CONTRACT
	var reprepared: Dictionary = _coordinator.prepare_load(SLOT)
	if not _require("E7 the slot prepares again once the contract matches",
			bool(reprepared.get("ok", false)), str(reprepared)):
		return
	# Deliberately minimal sections: if the gate below ever stopped firing, the
	# first provider would return a clean `save_provider_missing` instead of
	# dereferencing the world this fixture does not build.
	_coordinator._pending_load["sections"] = {"pkid": PackedByteArray([1, 2, 3, 4])}
	_facade.contract = OTHER_CONTRACT
	var restored: Dictionary = _coordinator.restore_prepared_game(_host)
	_expect("E8 restore_prepared_game -- the gate that runs AFTER the world exists "
		+ "and BEFORE any provider restores -- refuses with the same named code",
		not bool(restored.get("ok", true))
			and String(restored.get("code", "")) == _manifest_code,
		str(restored))

	# --- the legacy trio, end to end -----------------------------------------
	_facade.contract = CONTRACT
	var legacy_write: Dictionary = _write_slot(_build_manifest(null, true),
		PackedByteArray([9, 9, 9]))
	if not _require("E9 a pre-field archive (manifest entry without the key) writes",
			bool(legacy_write.get("ok", false)), str(legacy_write)):
		return
	var legacy: Dictionary = _coordinator.prepare_load(SLOT)
	if not _require("E10 ... and it is NOT refused: refusing every older archive "
			+ "would break saves that are otherwise compatible",
			bool(legacy.get("ok", false)), str(legacy)):
		return
	var legacy_bundle: Dictionary = legacy.get("bundle", {})
	var legacy_recorded: Dictionary = legacy_bundle.get("execution_contract", {})
	_expect("E11 ... and the deferral is recorded on the bundle, so the acceptance is "
		+ "explicit and attributable rather than silent",
		String(legacy_recorded.get("detail", "")) == "contract_unstated"
			and bool(legacy_recorded.get("deferred", false))
			and int(legacy_recorded.get("running", 0)) == CONTRACT,
		str(legacy_recorded))

	_write_slot(_build_manifest(null, true), PackedByteArray())
	var empty_state: Dictionary = _coordinator.prepare_load(SLOT)
	if not _require("E12 an old archive with no ideology state loads",
			bool(empty_state.get("ok", false)), str(empty_state)):
		return
	var empty_bundle: Dictionary = empty_state.get("bundle", {})
	var empty_recorded: Dictionary = empty_bundle.get("execution_contract", {})
	_expect("E13 ... and it is reported as having nothing to reinterpret, not as a "
		+ "verified identity",
		String(empty_recorded.get("detail", "")) == "contract_unstated_no_state"
			and not bool(empty_recorded.get("deferred", true)),
		str(empty_recorded))

	# The THIRD OUTCOME at the authoritative gate. E8 shows the gate refuses a
	# certified mismatch before any provider restores; this shows it does NOT
	# refuse a pre-field archive: the restore proceeds into the provider loop and
	# the failure is the deliberately absent world section. If the gate treated
	# "unstated" as "differs", the code below would be the manifest code instead.
	_write_slot(_build_manifest(null, true), PackedByteArray([5, 5, 5]))
	var deferred: Dictionary = _coordinator.prepare_load(SLOT)
	if _require("E14 a pre-field archive with ideology state prepares again "
			+ "(deferred, still not refused)",
			bool(deferred.get("ok", false)), str(deferred)):
		_coordinator._pending_load["sections"] = {"pkid": PackedByteArray([5, 5, 5])}
		var deferred_restore: Dictionary = _coordinator.restore_prepared_game(_host)
		_expect("E15 ... and the authoritative gate lets it THROUGH to the providers: "
			+ "the failure is the absent world section, not the contract code",
			String(deferred_restore.get("code", "")) == "save_provider_missing"
				and String(deferred_restore.get("code", "")) != _manifest_code,
			str(deferred_restore))
	print("[11.5] verdicts: matches=%s manifest_code=%s payload_code=%s"
		% [String(match_verdict_detail()), _manifest_code, _payload_code])


func match_verdict_detail() -> String:
	var verdict: Dictionary = _coordinator._execution_contract_verdict(
		_stamped(str(CONTRACT)), CONTRACT, true)
	return String(verdict.get("detail", "?"))


# --- helpers ----------------------------------------------------------------

func _stamped(text: String) -> Array:
	var entry := {"provider_id": "pkid", "schema_version": 2, "sections": ["pkid"],
		"state_hash": ""}
	entry[_key] = text
	return [entry]


func _build_manifest(contract_text = null, drop_identity := false) -> Array:
	var context := {"generator": _generator}
	var manifest: Array = []
	for provider in _coordinator._providers:
		var entry: Dictionary = provider.manifest_entry(context, false)
		if String(entry.get("provider_id", "")) == "pkid":
			if drop_identity:
				entry.erase(_key)
			elif contract_text != null:
				entry[_key] = contract_text
		manifest.append(entry)
	manifest.append({"provider_id": "technology_industry",
		"schema_version": _industry_revision,
		"sections": PackedStringArray(), "content_hash": ""})
	return manifest


func _manifest_entry(manifest: Array, provider_id: String) -> Dictionary:
	for entry in manifest:
		if String(entry.get("provider_id", "")) == provider_id:
			return entry
	return {}


func _provider(provider_id: String):
	for provider in _coordinator._providers:
		if String(provider.provider_id()) == provider_id:
			return provider
	return null


func _slot(slots: Array, slot_id: String) -> Dictionary:
	for slot in slots:
		if String(slot.get("slot_id", "")) == slot_id:
			return slot
	return {}


## A real PKSV container: the point is that the gate is exercised through the
## repository's own header / JSON / checksum path, not a hand-rolled dictionary.
func _write_slot(manifest: Array, pkid: PackedByteArray) -> Dictionary:
	var header := {
		"country_name": "execution contract fixture",
		"day": 1,
		"seed": 7,
		"width": 8,
		"height": 8,
		"saved_at": "fixture",
		"reason": "fixture",
		"provider_manifest": manifest,
	}
	var sections := {}
	for section_id in ["new_game_config", "world_clock", "dynamic_world", "environment",
			"pkfg", "journal", "player_context", "player_view"]:
		sections[section_id] = var_to_bytes({})
	sections["simulation_runtime"] = PackedByteArray()
	sections["pkcn"] = PackedByteArray()
	sections["ecp2"] = PackedByteArray()
	sections["preview"] = PackedByteArray()
	sections["pkid"] = pkid
	return _coordinator._repository.write_slot(SLOT, header, sections)


## The JSON header the repository actually wrote, read back from the .pksv file.
## Used to assert the WRITTEN FORM of the identity, which no in-memory dictionary
## can prove: the format decision only matters once it has been through JSON.
func _header_text() -> String:
	var path := String(_coordinator._repository._slot_path(SLOT))
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return ""
	file.get_buffer(4)
	file.get_32()
	var header_length := file.get_32()
	if header_length <= 0 or header_length > file.get_length() - 12:
		return ""
	return file.get_buffer(header_length).get_string_from_utf8()


func _cleanup() -> void:
	if _coordinator != null:
		_coordinator._repository.delete_manual_slot(SLOT)
		_coordinator._pending_load.clear()
		_coordinator._runtime_host = null
	# PK_SAVE_DIR is deliberately left pointing at the fixture directory: if
	# anything constructs a repository during teardown it must not land on the
	# player's slots.
	if _host != null:
		_host._generator = null
		_host.free()
		_host = null
	# MapGenerator is RefCounted (`class_name MapGenerator` with no `extends`), so
	# dropping the last reference is the release path; `free()` would be an error.
	_generator = null
	if _coordinator != null:
		_coordinator.free()
		_coordinator = null


func _require(label: String, ok: bool, detail: String = "") -> bool:
	_expect(label, ok, detail)
	return ok


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _finish(code: int) -> void:
	print("=== 11.5 execution contract manifest: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
