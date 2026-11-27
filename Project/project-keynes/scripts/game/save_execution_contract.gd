extends RefCounted

const ArchiveContract = preload("res://scripts/game/save_archive_contract.gd")

## Validates an incoming save's manifest, runtime schema, and execution contract.


static func _manifest_compatible(owner, raw_manifest) -> bool:
	if not owner._provider_registration_error.is_empty():
		return false
	if not raw_manifest is Array:
		return false
	var by_id := {}
	for raw in raw_manifest:
		if not raw is Dictionary:
			return false
		by_id[String(raw.get("provider_id", ""))] = raw
	var industry_entry: Dictionary = by_id.get(ArchiveContract.TECHNOLOGY_INDUSTRY_PROVIDER_ID, {})
	if int(industry_entry.get("schema_version", 1)) != ArchiveContract.TECHNOLOGY_INDUSTRY_REVISION:
		return false
	var expected_ids := {ArchiveContract.TECHNOLOGY_INDUSTRY_PROVIDER_ID: true}
	for provider in owner._providers:
		var provider_id := String(provider.provider_id())
		expected_ids[provider_id] = true
		if not by_id.has(provider_id):
			if provider.allows_missing_archive():
				continue
			return false
		if not provider.accepts_manifest(by_id[provider_id]):
			return false
	# A missing optional system must not silently erase that system's save data.
	for provider_id in by_id:
		if not expected_ids.has(provider_id):
			return false
	return true



static func _manifest_industry_revision(raw_manifest) -> int:
	if not raw_manifest is Array:
		return 1
	for raw in raw_manifest:
		if raw is Dictionary and String(raw.get("provider_id", "")) \
				== ArchiveContract.TECHNOLOGY_INDUSTRY_PROVIDER_ID:
			return int(raw.get("schema_version", 1))
	return 1


# --- Plan 11.5, the WHOLE-PACKAGE half ---------------------------------------
#
# `_manifest_compatible` answers "are these providers the ones this build can
# restore?". It cannot answer "is the stored cell-program EXECUTION CONTRACT
# this build's?" -- that identity now lives in the pkid manifest entry, and the
# decision needs a fact the manifest does not contain: what the running runtime
# is configured with. That fact only exists once a world has been built, so the
# decision is a separate, PURE function (`running` and `state_present` are
# inputs) called from three places that do not share a runtime:
#
#   * `list_slots()`            -- the pause menu. The runtime IS live, so a
#                                  certified mismatch greys the slot out early.
#   * `prepare_load()`          -- the session request, which runs BEFORE a world
#                                  exists (`world_runtime_host.gd:527`), so
#                                  `running` is normally 0 and the verdict
#                                  defers instead of guessing.
#   * `restore_prepared_game()` -- after the world was built, BEFORE the first
#                                  provider restores anything. This is the
#                                  authoritative gate: it is the last moment a
#                                  refusal can still leave the world untouched.

## The identity the LIVE runtime is running, or 0 when it cannot be stated
## (no world yet, or ideology unconfigured). 0 is "unknown", never "matches":
## the contract itself is a hash, so a zero value is not a contract.
static func _running_execution_contract(owner, host = null) -> int:
	var target = host if host != null else owner._runtime_host
	if target == null or not target.has_method("generator"):
		return 0
	var generator = target.generator()
	if generator == null or not generator.has_method("get_ideology_report"):
		return 0
	return owner._contract_from_report(generator.get_ideology_report())



static func _contract_from_report(owner, report) -> int:
	# The report is IdeologyFacade.report() -> DCWorldExt.get_ideology_report().
	# `{"configured": false}` means the owner is unconfigured (the facade says so
	# itself; the native report says so through the same key), and an older
	# extension build has no identity field at all. All three mean 0 = unknown,
	# never "matches": a hash of rule versions with no catalog attached is not
	# this world's contract.
	if not report is Dictionary:
		return 0
	var configured = report.get("configured", true)
	if configured is bool and not bool(configured):
		return 0
	return owner._contract_value(report.get(ArchiveContract.EXECUTION_CONTRACT_KEY, 0))


## Normalizes an identity read from a dictionary or from the save header.
## The header is JSON, and JSON hands a number back as int or float depending on
## how it was written, so a raw `int(...)` is not enough to compare identities.
static func _contract_value(value) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String or value is StringName:
		return String(value).to_int()
	return 0



static func _manifest_entry_for(raw_manifest, provider_id: String) -> Dictionary:
	if not raw_manifest is Array:
		return {}
	for raw in raw_manifest:
		if raw is Dictionary and String(raw.get("provider_id", "")) == provider_id:
			return raw
	return {}


## Whether the archive actually carries ideology state. Needed because the
## contract's absence only matters when there is contract-governed state that
## could be reinterpreted: an archive with no PKID payload restores to the empty
## ideology state, which cannot be governed by any contract.
static func _pkid_state_present(sections) -> bool:
	if not sections is Dictionary:
		return false
	return not PackedByteArray(sections.get("pkid", PackedByteArray())).is_empty()


## The whole-package execution-contract verdict.
##
## Returns {ok, code, detail, saved, running, deferred, message}.
##   ok=false  ONLY when the archive certified a contract that differs from the
##             running one (`detail == "contract_differs"`).
##   deferred  the archive did not certify the identity, so this gate did NOT
##             verify it. The PKID payload owns the same identity and compares it
##             exactly (`cell_program_execution_contract_mismatch`), so the load
##             is neither refused nor whitewashed: the deferral is recorded and
##             logged by the caller.
##
## LEGACY ARCHIVES (the backward-honest half). An archive written before this
## field existed has no key. That fact means UNSTATED -- never "matches" (which
## would be silent acceptance of an identity nobody checked) and never "differs"
## (which would refuse every archive on disk today, including ones whose PKID
## payload already carries the identical identity and will be compared exactly a
## few frames later). Plan 11.5's old-archive rule -- an older save must NOT be
## read under an unproven contract, and the refusal it names is
## `cell_program_execution_contract_mismatch` -- is therefore honoured by the
## layer that owns the identity, and this gate says out loud that it did not
## check instead of pretending it did.
static func _execution_contract_verdict(owner, raw_manifest, running: int,
		state_present: bool) -> Dictionary:
	var entry := _manifest_entry_for(raw_manifest, ArchiveContract.EXECUTION_CONTRACT_PROVIDER_ID)
	if entry.is_empty():
		# Pre-ideology archive: no pkid provider, so no contract-governed state.
		return owner._contract_verdict(true, "contract_no_provider", 0, 0, false)
	var saved: int = owner._contract_value(entry.get(ArchiveContract.EXECUTION_CONTRACT_KEY, 0))
	if running == 0:
		return owner._contract_verdict(true, "contract_unverifiable", 0, saved, saved != 0)
	if saved == 0:
		return owner._contract_verdict(true,
			"contract_unstated" if state_present else "contract_unstated_no_state",
			running, 0, state_present)
	if saved != running:
		return owner._contract_verdict(false, "contract_differs", running, saved, false)
	return owner._contract_verdict(true, "contract_matches", running, saved, false)



static func _contract_verdict(owner, ok: bool, detail: String, running: int, saved: int,
		deferred: bool) -> Dictionary:
	return {
		"ok": ok,
		"code": "" if ok else ArchiveContract.EXECUTION_CONTRACT_MANIFEST_CODE,
		"detail": detail,
		"saved": saved,
		"running": running,
		"deferred": deferred,
		"message": owner._contract_verdict_message(detail, running, saved),
	}



static func _contract_verdict_message(detail: String, running: int, saved: int) -> String:
	match detail:
		"contract_differs":
			return ("Save was written under a different cell-program execution "
				+ "contract (saved=%d running=%d); refused before any provider "
				+ "restored state.") % [saved, running]
		"contract_unstated":
			return ("Save predates the pkid execution-contract manifest identity; "
				+ "the PKID payload remains the authority (%s).") \
				% ArchiveContract.EXECUTION_CONTRACT_PAYLOAD_CODE
		"contract_unstated_no_state":
			return ("Save carries no ideology state and no execution-contract "
				+ "identity; nothing can be reinterpreted.")
		"contract_unverifiable":
			return ("The running execution contract is not available yet; the "
				+ "whole-package comparison is deferred to the PKID payload.")
		"contract_no_provider":
			return "Save predates the ideology provider."
	return ""
