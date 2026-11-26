extends RefCounted

## Shared save archive constants and coordinator result values.

const REQUIRED_SECTIONS := [
	"new_game_config", "world_clock", "dynamic_world", "environment",
	"simulation_runtime",
	"pkcm", "pkcn", "ecp2", "pkgp", "pkfg", "journal",
	"player_context", "player_view", "preview", "pktr", "pkef", "pkid", "pkai",
	"pkmi",
]
## Providers that an older save may legitimately lack. They restore from an
## empty section (a fresh runtime) instead of refusing the load.
const PKMI_SCHEMA := 1

const TECHNOLOGY_INDUSTRY_PROVIDER_ID := "technology_industry"
const TECHNOLOGY_INDUSTRY_REVISION := 2
## Plan 11.5, the WHOLE-PACKAGE half. The ideology execution-contract identity
## already travels inside the PKID payload (the native reader refuses a payload
## stamped by a different contract with `cell_program_execution_contract_mismatch`).
## It also has to enter the CONTAINER-level compatibility check, so the manifest
## of every provider is asked whether it can certify the same identity.
##
## The refusal code here is deliberately NOT the payload's. The payload code is a
## native verdict reached after restore has begun; this one is a GDScript
## pre-flight reached before any provider has touched the world. Sharing one
## string would make the two layers indistinguishable in a log -- and in a test,
## where an assertion that "the whole-package gate refused" could be satisfied by
## the payload reader instead, passing while the new gate did nothing.
const EXECUTION_CONTRACT_KEY := "execution_contract_hash"
const EXECUTION_CONTRACT_PROVIDER_ID := "pkid"
const EXECUTION_CONTRACT_PAYLOAD_CODE := "cell_program_execution_contract_mismatch"
const EXECUTION_CONTRACT_MANIFEST_CODE := \
	"cell_program_execution_contract_manifest_mismatch"


static func result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}


## Preserve the precise save-boundary condition for failure diagnostics.
static func blocked_result(code: String, message: String, condition: String) -> Dictionary:
	var blocked := result(false, code, message)
	blocked["blocking_condition"] = condition
	return blocked
