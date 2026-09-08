extends RefCounted

# PKSR v2 fixed scalar header contract.
#
# The layout mirrors build_save_bundle in gdext/src/native_simulation_host.cpp.
# It lives here rather than inline in GameSaveCoordinator for two reasons: the
# offsets and the section bits are one contract that has to move together with
# the C++ writer, and the validator has to be testable without dragging in the
# coordinator's autoload dependencies.

# Byte offsets into the fixed scalar header.
const OFFSET_MAGIC := 0
const OFFSET_VERSION := 4
const OFFSET_REQUEST_ID := 8
const OFFSET_COMMITTED_DAY := 16
const OFFSET_SPEED := 24
const OFFSET_PAUSED := 32
const OFFSET_GENERATION := 33
const OFFSET_STATE_HASH := 41
const OFFSET_ENVIRONMENT_GENERATION := 49
const OFFSET_ENVIRONMENT_DAY := 57
const OFFSET_CLIMATE_ANOMALY := 65
const OFFSET_TIME_DEBT := 73
const OFFSET_DOMAIN_ABI := 81
const OFFSET_SECTION_MASK := 85
const SCALAR_HEADER_SIZE := 89

# Smallest bundle the host can emit: scalar header, empty command tail, producer
# cursors and the trailing checksum.
const MIN_BUNDLE_SIZE := 2161

const BUNDLE_VERSION := 2
# Mirrors RUNTIME_DOMAIN_ABI_VERSION. The legacy host envelope stays at 1; the
# POD section ABI is versioned separately inside the DPD2 section.
const DOMAIN_ABI_VERSION := 1

# Mirrors RUNTIME_SAVE_SECTION_* in gdext/src/runtime_pod_protocol.h.
const SECTION_RUNTIME_ENVELOPE := 1
const SECTION_DOMAIN_POD := 2
const SECTION_CLIMATE := 4
const SECTION_COUNTRY := 8
const SECTION_KNOWN := SECTION_RUNTIME_ENVELOPE | SECTION_DOMAIN_POD | SECTION_CLIMATE \
	| SECTION_COUNTRY


static func section_mask(bytes: PackedByteArray) -> int:
	if bytes.size() < OFFSET_SECTION_MASK + 4:
		return 0
	return int(bytes.decode_u32(OFFSET_SECTION_MASK))


static func has_climate_section(bytes: PackedByteArray) -> bool:
	return (section_mask(bytes) & SECTION_CLIMATE) != 0


static func has_country_section(bytes: PackedByteArray) -> bool:
	return (section_mask(bytes) & SECTION_COUNTRY) != 0


# Validates the fixed ABI header before the bytes reach a restore provider. The
# container section hash is SaveRepository's job; this is only about the header.
#
# `report` is the dictionary poll_runtime_save returned, when available. Passing
# it makes the header and the host's own view cross-check each other, so codec
# drift fails on the machine that produced the bundle instead of on the machine
# that later tries to load it.
static func valid(bytes: PackedByteArray, report: Dictionary = {}) -> bool:
	if bytes.size() < MIN_BUNDLE_SIZE:
		return false
	if bytes.slice(OFFSET_MAGIC, OFFSET_MAGIC + 4).get_string_from_ascii() != "PKSR":
		return false
	# PKSR v1 carried no ABI/section header and is rejected rather than guessed at.
	if int(bytes.decode_u32(OFFSET_VERSION)) != BUNDLE_VERSION:
		return false
	var abi := int(bytes.decode_u32(OFFSET_DOMAIN_ABI))
	if abi != DOMAIN_ABI_VERSION:
		return false
	# section_mask is a bitmask, not a literal. The host always writes at least
	# RUNTIME_ENVELOPE|DOMAIN_POD and adds CLIMATE once the climate store carries
	# cells, so an equality test against a single section can never hold.
	var mask := int(bytes.decode_u32(OFFSET_SECTION_MASK))
	if (mask & SECTION_RUNTIME_ENVELOPE) == 0:
		return false
	# An unknown section bit means the writer knows a section this build cannot
	# restore; refusing beats a partial restore.
	if (mask & ~SECTION_KNOWN) != 0:
		return false
	if report.has("section_mask") and int(report["section_mask"]) != mask:
		return false
	if report.has("runtime_domain_abi_version") \
			and int(report["runtime_domain_abi_version"]) != abi:
		return false
	return true
