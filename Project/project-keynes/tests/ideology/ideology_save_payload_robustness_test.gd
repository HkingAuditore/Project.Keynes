extends SceneTree
## Plan 18.2 requires "every 11.7 save time point" PLUS "corrupt / truncated /
## old-schema REFUSED" PLUS "native writer/reader, snapshot ABI ... consistent".
## Six of the seven 11.7 TIME points are covered by sibling fixtures. This one is
## the ROBUSTNESS half: it does not compare two timelines, it attacks the byte
## stream and proves the runtime refuses it -- and that a refusal is ATOMIC.
##
## THE TWO PAYLOADS
##
##   `capture_effect_state()` -> PKEF   (EffectRuntime,  effect_runtime.cpp:7234)
##   `capture_ideology_state()` -> PKID (NativeIdeologyRuntime, ideology_runtime.cpp:6393)
##
## THE CONTRACT IS THE LIST OF VALIDATION LAYERS. Every layer below is a place
## where `restore()` can say no, and every layer gets its own case here. The
## reason code is quoted verbatim because it IS the layer's identity.
##
##   PKID  (ideology_runtime.cpp)                        reason code
##   ---------------------------------------------------------------
##   L1  not configured (:6510)                 ideology_runtime_unconfigured
##   L2  header read + magic (:6514-6517)       ideology_save_header_invalid
##   L3  schema, fail-closed, no migration (:6520)  ideology_save_schema_unsupported
##   L4  catalog hash (:6521)                   ideology_save_catalog_mismatch
##   L5  producer high-watermark count/shape (:6525-6537)
##                                              ideology_save_producer_count_invalid
##                                              ideology_save_producer_invalid
##   L6  points header / worker_origin byte (:6541-6543)
##                                              ideology_save_points_header_invalid
##   L7  country count bound (:6544)            ideology_save_country_count_invalid
##   L8  per-country row shape (:6547-6587): era range, offer flags, and the exact
##       known_bits / gate_bits word counts   -> ideology_save_country_invalid
##   L9  point history ring (:6568-6571)        ideology_save_point_history_invalid
##   L10 offer rows (:6589)                     ideology_save_offer_invalid
##   L11 banned_bits (:6596)                    ideology_save_ban_invalid
##   L12 idea count (:6598)                     ideology_save_idea_count_invalid
##   L13 per-idea row shape (:6601-6626)        ideology_save_idea_invalid
##   L14 transaction ids (:6629, :6654)         ideology_save_transition_invalid
##   L15 synergy transition rows (:6634, :6650) ideology_save_synergy_transition_invalid
##   L16 effect-instance refs (:6659, :6674)    ideology_save_effect_instance_count_invalid
##                                              ideology_save_effect_instance_invalid
##   L17 command count (:6682)                  ideology_save_command_count_invalid
##   L18 per-command read (:6692)               ideology_save_command_invalid
##   L19 per-command shape, validate_command_shape (:6693)  its own code
##   L20 command ordering, is_sorted (:6697)    ideology_save_command_order_invalid
##   L21 trailer SAVE_END AND cursor == size (:6698)   ideology_save_truncated
##   L22 STATE HASH, with rollback (:6747)      ideology_save_state_hash_mismatch
##   L23 saved effect instances still exist (:6758-6775) ideology_effect_instance_missing
##   L24 effect runtime present (:6783)         ideology_effect_runtime_unavailable
##   L25 schema < 2 with an active row (:6788-6791) ideology_legacy_active_state_unsupported
##   L26 BINDING identity: recomputed binding id / generation / signature /
##       program hash AND `has_external_binding_pod` (:6793-6812)
##                                     ideology_effect_binding_missing_or_mismatched
##   L27 pending transactions: every live transaction the Effect side holds for
##       this country must be listed by the payload and vice versa (:6823-6830).
##       The code is the Effect side's own and travels out verbatim:
##                                     effect_external_pending_transaction_unknown
##                                     effect_external_pending_transaction_missing
##                                     effect_external_pending_source_mismatch
##
##   PKEF  (effect_runtime.cpp)                          reason code
##   ---------------------------------------------------------------
##   K1  not configured (:7395)                 effect_runtime_unconfigured
##   K2  fewer than 8 bytes (:7396)             pkef_truncated
##   K3  magic (:7403-7405)                     pkef_header_incompatible
##   K4  schema (:7409-7410)                    pkef_schema_unsupported
##   K5  protocol + catalog hash (:7411-7413)   catalog_hash_mismatch
##   K6  runtime cursors + instance count (:7418-7427)
##                                              pkef_instances_invalid
##                                              pkef_runtime_cursor_invalid
##   K7  per-instance row (:7446-7511)          pkef_instance_truncated_or_metric_mismatch
##                                              pkef_instance_identity_invalid
##                                              pkef_instance_tombstone_invalid
##   K8  instance metadata vs catalog (:7538-7547)
##                                              pkef_instance_catalog_metadata_mismatch
##   K9  metric slab / presence tails (:7549-7561) pkef_instance_metrics_truncated
##                                              pkef_instance_presence_truncated
##                                              pkef_instance_presence_invalid
##   K10 candidate table (:7565-7582)           pkef_candidate_cursor_invalid
##                                              pkef_candidate_invalid
##   K11 transaction table (:7583-7648)         pkef_transactions_invalid
##                                              pkef_transaction_truncated
##                                              pkef_transaction_identity_invalid
##   K12 transaction transitions (:7672-7702)   pkef_transaction_transition_invalid
##                                              pkef_transaction_state_invalid
##                                              pkef_transaction_ack_incomplete
##   K13 command rows + definition match (:7707-7780)
##                                              pkef_command_truncated
##                                              pkef_command_invalid
##                                              pkef_command_definition_mismatch
##   K14 ack mask derived from the commands (:7848) pkef_transaction_ack_mask_invalid
##   K15 plan hash, an FNV over every transaction field (:7850-7915)
##                                              pkef_transaction_plan_hash_invalid
##   K16 external binding table (:7921-7948)    pkef_external_binding_count_invalid
##                                              pkef_external_binding_truncated
##                                              pkef_external_binding_invalid
##   K17 era-reward offer (:7954-8007)          pkef_era_reward_truncated
##                                              pkef_era_reward_identity_invalid
##                                              era_reward_cross_section_mismatch
##   K18 end marker (:8019-8020)                pkef_end_marker_missing
##   K19 trailing bytes / cursor coherence (:8021-8023)
##                                              pkef_trailing_or_cursor_invalid
##
##   PKEF has NO whole-payload state hash. Its integrity rests on K15 (every
##   transaction field is covered by an FNV plan hash) plus the per-row shape
##   checks. Fields outside a transaction -- the header cursors, instance
##   counters, metric values -- are covered by nothing. Section F MEASURES that
##   instead of assuming it, and prints the gap as [FINDING].
##
## ATOMICITY. Every "refused" case asserts the runtime is left BYTE-IDENTICAL:
## `capture()` before the attempt and again after it must be equal. That is the
## strongest available statement of "not half-restored" -- it covers the state
## hash's own `rollback()` (:6731-6746) and the parse-only-then-commit design of
## PKEF (:8025-8027) with one measurement.
##
## WHAT THIS FIXTURE CURRENTLY FINDS (printed as [FINDING], measured not assumed)
##
##   G1  PKID `last_day` (offset 16) is outside `compute_state_hash()`: a payload
##       whose day is rewritten from 0 to 1007 loads with ok=true and the runtime
##       ADOPTS 1007.
##   G2  PKID `submit_order` (offset 24) is outside the hash as well; a rewritten
##       value loads with ok=true and no public API exposes it.
##   G3  PKEF has no whole-payload hash. `current_day` (offset 20) is only
##       bounds-checked at -1, so a rewritten day becomes the runtime's day.
##   G4  PKID: 14 of 69 sampled single-byte corruptions are ACCEPTED. The
##       uncovered bytes are the header fields of G1/G2 plus
##       `_points_revision_seen` (:6408) and the per-country fields the hash never
##       mixes in -- `trade_paid_day` (:6423), the six split ledger fields
##       (:6424-6430), `offer.*` (:6433-6440) and `banned_bits` (:6441).
##   G5  PKEF: 16 of 38 sampled single-byte corruptions are ACCEPTED (the header
##       cursors and most of the era-reward block). Its integrity is per-row, not
##       per-payload: transactions are covered by an FNV plan hash (:7850-7915),
##       nothing else is.
##
##   None of the five is a refusal this fixture could assert; each is measured and
##   named so the gap is visible instead of being mistaken for coverage.
##
## THE ABI HALF. A payload that only round-trips proves nothing about its layout,
## so every header field is read at a FIXED OFFSET and compared against the
## runtime's own report of the same number:
##
##   PKID  u32 @ 0   magic 0x44494B50        i32 @ 4  schema 11
##         u64 @ 8   catalog hash   == get_ideology_business_state().catalog_hash
##         i64 @ 16  last day       == get_ideology_business_state().committed_day
##         u64 @ 24  submit order   u64 @ 32 state hash (echoed by restore())
##         u64 @ 40  producer high-watermark count, then 12 bytes per row
##         u64 @ 40+8+12n  points_revision_seen
##         u8       worker_origin, u64 country count, then the first country row
##                  whose handle must equal the world's own country handle
##
##   PKEF  u32 @ 0 magic 0x46454B50, i32 @ 4 schema 14, i32 @ 8 protocol 1
##         u64 @ 12 catalog hash  == get_effect_report().catalog_hash
##         i64 @ 20 current day   == get_effect_report().current_day
##         i64 @ 28 last completed day, i64 @ 36 run day, i32 @ 44 run cursor
##         i64 @ 48 next transaction id, i64 @ 56 acked transaction id
##         u64 @ 64 next activation sequence
##         u32 @ 72 instance slots, i32 @ 76 candidate cursor,
##         u32 @ 80 candidate count, u32 @ 84 transactions, u32 @ 88 bindings
##
## The fixture deliberately equips NOTHING for the byte-level attacks: a payload
## with no card equipped still carries a country row, its points, its ledger and
## its history ring, so every byte layer is exercised -- and it has no effect
## bindings that would smuggle PKID past a byte-level refusal into L26. The
## equipped payload is used only where L26 IS the point (wrong-order restore).
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_payload_robustness_test.gd

const WIDTH := 8
const HEIGHT := 8
## 8x8 keeps the fixture small; `c >> 3` is `c / 8` without an integer-division
## warning for the row index.
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028
## A permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0). Its
## equip creates an EXTERNAL BINDING in the Effect runtime but zero one-shot
## Effect instances, so the ordering test needs no acker: the card is ACTIVE as
## soon as the transition starts (`ideology_runtime.cpp:3596-3607` sets the
## location and syncs the binding BEFORE any ACK is collected).
const CARD_KEY := "idea.public_hygiene"
const Q16_ONE := 65536
## `LevelPublicHygieneL2.understanding_threshold_q16`. Enough understanding to
## make the equip eligible without a level transaction.
const LEVEL2_UNDERSTANDING_Q16 := 524288

# ---- PKID wire format ---------------------------------------------------
# `ideology_runtime.cpp:42` magic, `:6397-6399` header, `:6514-6517` reader.
const PKID_MAGIC := 0x44494B50
# 11: PKID gained the plan 9.3 basis dates (confirmed_day / eligible_from_day)
# immediately before the trailer, so the layout changed and the version with it.
# 12: PKID also carries the plan 11.5 execution-contract identity (one u64) between
# the two basis dates and the trailer, so the layout changed again.
# 13: PKID also carries the FULL applied-program basis (plan 18.2): a variable-length
# block of (country, program) rows between the command table and the two dates, closed
# by a u32 byte-length so the tail stays addressable from the END of the payload.
# 14: PKID also carries the LOCAL SCALAR BASIS and the projection's sample day (plan
# 18.5): a second variable-length block of (country, metric id, Q16 value) rows right
# after the applied block, then one i64. Both additions sit BEFORE the two dates, so
# every offset already addressed from the END keeps its distance from `size`.
const PKID_SCHEMA := 14
# Two s64 basis dates (confirmed_day / eligible_from_day, plan 9.3) sit between the
# basis block and the 4-byte trailer. Addressing from the tail has to skip
# them, which is what the earlier `size() - 4 - 8` missed.
const PKID_BASIS_DATES_BYTES := 16
# Plan 11.5: the execution-contract identity (one u64) sits between the two basis dates
# and the 4-byte trailer, so tail addressing skips it too.
const PKID_CONTRACT_BYTES := 8
# Plan 18.5: one s64 sample day between the dates and the scalar block.
const PKID_SAMPLE_DAY_BYTES := 8
# Plan 18.2: the applied-basis block ends with a u32 holding its own total byte length
# (count field + rows). That one field is what makes the block addressable from the
# tail: without it the block's start could only be learnt by parsing from the front.
const PKID_BASIS_LEN_BYTES := 4
# Plan 18.5: the scalar block ends with the same kind of self-delimiting u32.
const PKID_SCALAR_LEN_BYTES := 4
# Per-row fixed bytes: u64 country_handle + u32 program_key length + i32 selector_kind
# + u32 selector_id length + i32 param0 + i32 param1 + u64 terms_digest. The two
# strings are the only variable part, and their lengths are read from the row.
const PKID_BASIS_ROW_FIXED_BYTES := 32
# Plan 18.5 scalar row: u64 country_handle + i32 metric_id + i64 value_q16. No
# variable part at all, which is what lets the tail bound a lying count by `(left)/20`.
const PKID_SCALAR_ROW_BYTES := 20
# Row-relative offsets inside a basis row, derived from the fixed layout above.
const PKID_BASIS_ROW_KEY_LEN := 8
const PKID_BASIS_ROW_KEY := 12
const PKID_OFF_MAGIC := 0
const PKID_OFF_SCHEMA := 4
const PKID_OFF_CATALOG := 8
const PKID_OFF_LAST_DAY := 16
const PKID_OFF_SUBMIT_ORDER := 24
const PKID_OFF_STATE_HASH := 32
const PKID_OFF_PRODUCER_COUNT := 40
const PKID_HEADER_SIZE := 40

# ---- PKEF wire format ---------------------------------------------------
# `effect_runtime.cpp:30` magic, `:7237-7248` header, `:7396-7413` reader.
const PKEF_MAGIC := 0x46454B50
const PKEF_SCHEMA := 14
const PKEF_PROTOCOL := 1
const PKEF_OFF_MAGIC := 0
const PKEF_OFF_SCHEMA := 4
const PKEF_OFF_PROTOCOL := 8
const PKEF_OFF_CATALOG := 12
const PKEF_OFF_CURRENT_DAY := 20
const PKEF_OFF_LAST_COMPLETED_DAY := 28
const PKEF_OFF_RUN_DAY := 36
const PKEF_OFF_RUN_CURSOR := 44
const PKEF_OFF_NEXT_TRANSACTION := 48
const PKEF_OFF_ACKED_TRANSACTION := 56
const PKEF_OFF_NEXT_ACTIVATION := 64
const PKEF_OFF_INSTANCE_COUNT := 72
const PKEF_OFF_CANDIDATE_CURSOR := 76
const PKEF_OFF_CANDIDATE_COUNT := 80
const PKEF_OFF_TRANSACTION_COUNT := 84
const PKEF_OFF_BINDING_COUNT := 88
## The era-reward block starts right after the binding count and is the LAST
## fixed-offset region of the stream. Valid only while the instance and the
## transaction tables are EMPTY (the PLAIN payload) -- the cases that use these
## offsets assert that precondition first. Layout from `effect_runtime.cpp`
## :7363-7376 (writer) and :7954-7981 (reader): player_country u64 @ +0,
## next_plan_id i64 @ +8, next_generation i64 @ +16, offer.plan_id i64 @ +24,
## offer.generation i64 @ +32, pool_index i32 @ +40, milestone_technology i32
## @ +44, country_handle u64 @ +48, country_generation u32 @ +52, status i32
## @ +60, selected_choice i32 @ +64, transaction_id i64 @ +68, plan_hash u64
## @ +76, then the error string and the alternative rows.
const PKEF_ERA_REWARD_OFFSET := 92
const PKEF_OFF_ERA_NEXT_PLAN_ID := PKEF_ERA_REWARD_OFFSET + 8
const PKEF_OFF_ERA_STATUS := PKEF_ERA_REWARD_OFFSET + 60

## The day the runtime is left on after the equip lead. Only used to give the
## equipped payload a non-trivial `last_day`; nothing asserts a specific value.
const EQUIP_DAYS := 3

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _findings := 0
var _catalogs := {}


func _init() -> void:
	_run()


func _run() -> void:
	_catalogs = _compile_catalogs()
	if _catalogs.is_empty():
		_finish()
		return
	var ids: PackedStringArray = _catalogs["native_ideology"].get(
		"ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled ideology catalog", dense >= 0,
		"%s -> dense=%d of %d" % [CARD_KEY, dense, ids.size()])
	if dense < 0:
		_finish()
		return

	# ==================================================================
	# A. THE WRITER: one payload pair, deterministic bytes, pinned layout
	# ==================================================================
	var source: Dictionary = _new_world("source")
	var handle: int = int(source["handle"])
	# One ideology day so the payload carries a real last_day, a real points
	# ledger and a real history ring instead of an empty shell.
	_run_one_ideology_day(source["ext"], 0, "source/day0")
	var plain: Dictionary = _capture_pair(source["ext"], "PLAIN")
	if plain.is_empty():
		_finish()
		return
	_expect_pkid_abi(plain["pkid"], source["ext"], handle, "PLAIN")
	_expect_pkef_abi(plain["pkef"], source["ext"], "PLAIN")
	_expect_ideology_day_abi(plain["pkid"], source["ext"], "PLAIN")
	# The business snapshot the PLAIN payload was taken from. It is NOT the same
	# number as `source_business` below: the equip lead moves points, the idea set
	# and the bitsets, so the control branch has to be compared against THIS one.
	var plain_business: Dictionary = source["ext"].get_ideology_business_state()
	var plain_snapshot: Dictionary = source["ext"].get_ideology_snapshot(handle)
	print("[rob/PLAIN] source business hash=%s points=%s ideas=%s committed_day=%s"
		% [str(plain_business.get("hash", "?")),
			str(plain_business.get("points", "?")),
			str(plain_business.get("ideas", "?")),
			str(plain_business.get("committed_day", "?"))])

	# Byte determinism: the same state must serialize to the same bytes. Without
	# this the round-trip comparisons further down would be measuring a generator
	# that changes every call.
	var again: Dictionary = _capture_pair(source["ext"], "PLAIN-again")
	_expect("PLAIN: PKID capture is byte-deterministic (two captures, identical "
		+ "bytes)", again["pkid"] == plain["pkid"],
		"%d vs %d bytes, first diff @%d" % [plain["pkid"].size(),
			again["pkid"].size(), _first_diff(plain["pkid"], again["pkid"])])
	_expect("PLAIN: PKEF capture is byte-deterministic", again["pkef"] == plain["pkef"],
		"%d vs %d bytes, first diff @%d" % [plain["pkef"].size(),
			again["pkef"].size(), _first_diff(plain["pkef"], again["pkef"])])
	_expect("PLAIN: PKID is a PackedByteArray, non-empty and larger than its header",
		plain["pkid"].size() > PKID_HEADER_SIZE,
		"%d bytes" % plain["pkid"].size())
	_expect("PLAIN: PKEF is a PackedByteArray, non-empty and larger than its header",
		plain["pkef"].size() > PKEF_OFF_BINDING_COUNT + 4,
		"%d bytes" % plain["pkef"].size())
	_expect("PLAIN: PKID and PKEF are different streams (different magic, "
		+ "different length)", plain["pkid"] != plain["pkef"],
		"%d vs %d bytes" % [plain["pkid"].size(), plain["pkef"].size()])

	# ==================================================================
	# B. THE EQUIPPED PAYLOAD (source of the L26 ordering test)
	# ==================================================================
	var armed: Dictionary = _equip_until_active(source, dense)
	if armed.is_empty():
		_finish()
		return
	_expect_pkid_abi(armed["pkid"], source["ext"], handle, "ARMED")
	_expect_pkef_abi(armed["pkef"], source["ext"], "ARMED")
	# -- the plan 18.2 applied-program basis, as DATA -------------------
	# The basis must be what the projection ACTUALLY folds, not "one row per card in
	# play". This world never ACKs the equip, so plan 10.1 says a pending EQUIP
	# contributes NOTHING -- and the basis must be EMPTY even though the card is
	# ACTIVE. Asserting `1 row` here would have encoded the opposite rule and quietly
	# disagreed with `collect_effect_activations`, which is the whole reason the level
	# selection was factored out into one shared helper.
	#
	# (The non-empty case lives in `ideology_save_basis_and_midmaterialize_test`, whose
	# world serves the native Effect adapters and therefore SETTLES the equip.)
	var armed_tail: Dictionary = _pkid_tail(armed["pkid"])
	var armed_walk: Dictionary = _walk_basis_block(armed["pkid"],
		int(armed_tail["basis_block_off"]))
	_expect("ARMED: the basis block parses and its length field is honest",
		String(armed_walk["error"]).is_empty()
			and int(armed_walk["end"]) == int(armed_tail["basis_len_off"]),
		"error=%s end=%d expected=%d" % [String(armed_walk["error"]),
			int(armed_walk["end"]), int(armed_tail["basis_len_off"])])
	var armed_active: int = _active_locations(
		source["ext"].get_ideology_snapshot(handle))
	_expect("18.2 basis: a card whose EQUIP is still PENDING is ACTIVE but has no "
		+ "basis row (plan 10.1: pending contributes nothing)",
		armed_active > 0 and int(armed_walk["rows"]) == 0,
		"active=%d rows=%d" % [armed_active, int(armed_walk["rows"])])
	print("[rob/ARMED] basis: rows=%d (pending equip) block=%d bytes"
		% [int(armed_walk["rows"]), int(armed_tail["basis_block_bytes"])])
	var source_business: Dictionary = source["ext"].get_ideology_business_state()
	print("[rob/ARMED] source business hash=%s points=%s ideas=%s committed_day=%s"
		% [str(source_business.get("hash", "?")),
			str(source_business.get("points", "?")),
			str(source_business.get("ideas", "?")),
			str(source_business.get("committed_day", "?"))])

	# ==================================================================
	# C. THE TARGET: one freshly built world, reused for every refusal
	# ==================================================================
	# Reuse is sound BECAUSE every case asserts the runtime is byte-identical
	# afterwards: a case that corrupts the target makes the NEXT case's
	# pre/post comparison fail too, so the defect cannot hide behind the reuse.
	var target_world: Dictionary = _new_world("target")
	var target: Object = target_world["ext"]
	var target_handle: int = int(target_world["handle"])
	_run_one_ideology_day(target, 0, "target/day0")
	_expect("TARGET: the country handle matches the source world", target_handle
		== handle, "%d vs %d" % [target_handle, handle])
	var target_base: PackedByteArray = target.capture_ideology_state()
	var target_base_effect: PackedByteArray = target.capture_effect_state()
	_expect("TARGET: a freshly built world captures its own PKID",
		target_base.size() > PKID_HEADER_SIZE, "%d bytes" % target_base.size())
	_expect("TARGET: two independently built worlds with the same construction "
		+ "serialize to IDENTICAL PKID bytes", target_base == plain["pkid"],
		"%d vs %d bytes, first diff @%d" % [target_base.size(),
			plain["pkid"].size(), _first_diff(target_base, plain["pkid"])])

	print("")
	print("[rob] ===== PKID refusals (ideology_runtime.cpp:6509-6848) =====")
	# -- L2 magic -----------------------------------------------------
	var bad_magic: PackedByteArray = plain["pkid"].duplicate()
	bad_magic.encode_u8(PKID_OFF_MAGIC, bad_magic.decode_u8(PKID_OFF_MAGIC) ^ 0xFF)
	_refuse_pkid(target, "L2 PKID wrong magic (offset 0 flipped)", bad_magic,
		"ideology_save_header_invalid")
	# -- L3 schema: old and future, the "old save refused" requirement -
	var old_schema: PackedByteArray = plain["pkid"].duplicate()
	old_schema.encode_s32(PKID_OFF_SCHEMA, PKID_SCHEMA - 1)
	_refuse_pkid(target, "L3 PKID OLD schema (%d -> %d)"
		% [PKID_SCHEMA, PKID_SCHEMA - 1], old_schema,
		"ideology_save_schema_unsupported")
	var future_schema: PackedByteArray = plain["pkid"].duplicate()
	future_schema.encode_s32(PKID_OFF_SCHEMA, PKID_SCHEMA + 1)
	_refuse_pkid(target, "L3 PKID FUTURE schema (%d -> %d)"
		% [PKID_SCHEMA, PKID_SCHEMA + 1], future_schema,
		"ideology_save_schema_unsupported")
	var zero_schema: PackedByteArray = plain["pkid"].duplicate()
	zero_schema.encode_s32(PKID_OFF_SCHEMA, 0)
	_refuse_pkid(target, "L3 PKID schema 0 (pre-v1 legacy stream)", zero_schema,
		"ideology_save_schema_unsupported")
	# -- L4 catalog hash ----------------------------------------------
	var bad_catalog: PackedByteArray = plain["pkid"].duplicate()
	bad_catalog.encode_u64(PKID_OFF_CATALOG,
		bad_catalog.decode_u64(PKID_OFF_CATALOG) ^ 1)
	_refuse_pkid(target, "L4 PKID catalog hash (low bit flipped)", bad_catalog,
		"ideology_save_catalog_mismatch")
	# -- L5 producer count --------------------------------------------
	var bad_producer_count: PackedByteArray = plain["pkid"].duplicate()
	# -1 is the same 64-bit pattern as 0xFFFFFFFFFFFFFFFF, which GDScript cannot
	# write as a literal.
	bad_producer_count.encode_u64(PKID_OFF_PRODUCER_COUNT, -1)
	_refuse_pkid(target, "L5 PKID producer high-watermark count (unbounded)",
		bad_producer_count, "ideology_save_producer_count_invalid")
	# -- L6 worker_origin byte ----------------------------------------
	var layout: Dictionary = _pkid_layout(plain["pkid"])
	var off_worker: int = int(layout["worker_origin_off"])
	var bad_worker: PackedByteArray = plain["pkid"].duplicate()
	bad_worker.encode_u8(off_worker, 2)
	_refuse_pkid(target, "L6 PKID worker_origin byte = 2 (offset %d)" % off_worker,
		bad_worker, "ideology_save_points_header_invalid")
	# -- L7 country count ---------------------------------------------
	var off_country_count: int = int(layout["country_count_off"])
	var bad_country_count: PackedByteArray = plain["pkid"].duplicate()
	bad_country_count.encode_u64(off_country_count, 1 << 40)
	_refuse_pkid(target, "L7 PKID country count = 2^40 (offset %d)"
		% off_country_count, bad_country_count, "ideology_save_country_count_invalid")
	# -- L8 per-country row shape -------------------------------------
	var off_era: int = int(layout["unlocked_era_off"])
	var bad_era: PackedByteArray = plain["pkid"].duplicate()
	bad_era.encode_s32(off_era, 99)
	_refuse_pkid(target, "L8 PKID per-country row: unlocked_era = 99 (offset %d)"
		% off_era, bad_era, "ideology_save_country_invalid")
	# -- L17 command count --------------------------------------------
	# The country row's interior is variable-length (bit sets, offer ids, 16
	# history entries) and, since v13, the command table is followed by the applied-basis
	# block, also variable-length. So the command table is addressed from the TAIL:
	# trailer, contract, the two dates, the basis block's own length field, then the
	# block, and `command_count` immediately before the block.
	var tail: Dictionary = _pkid_tail(plain["pkid"])
	var cmd_count_off: int = int(tail["command_count_off"])
	_expect("L17 PKID ABI: the tail is addressable from the end (block @ %d, %d bytes, "
		% [int(tail["basis_block_off"]), int(tail["basis_block_bytes"])]
		+ "%d rows, command count @ %d)"
		% [int(tail["basis_row_count"]), cmd_count_off],
		cmd_count_off > PKID_HEADER_SIZE and int(tail["basis_block_bytes"]) >= 4,
		str(tail))
	_expect("L17 PKID ABI: the u64 immediately before the basis block (@ %d) is the "
		% cmd_count_off + "pending command count, and it is 0 for a command-free "
		+ "world", plain["pkid"].decode_u64(cmd_count_off) == 0,
		str(plain["pkid"].decode_u64(cmd_count_off)))
	var bad_cmd_count: PackedByteArray = plain["pkid"].duplicate()
	bad_cmd_count.encode_u64(cmd_count_off, 1 << 40)
	_refuse_pkid(target, "L17 PKID command count = 2^40 (offset %d)"
		% cmd_count_off, bad_cmd_count, "ideology_save_command_count_invalid")
	# -- L23: the plan 18.2 applied-program basis ----------------------
	# The block must be STRUCTURALLY what the reader believes it is before any value is
	# interpreted: the declared length must be the truth about the rows behind it.
	var basis_walk: Dictionary = _walk_basis_block(plain["pkid"],
		int(tail["basis_block_off"]))
	_expect("18.2 basis block: walking its rows lands exactly on the length field (@ %d)"
		% int(tail["basis_len_off"]), String(basis_walk["error"]).is_empty()
		and int(basis_walk["end"]) == int(tail["basis_len_off"]),
		"error=%s end=%d expected=%d" % [String(basis_walk["error"]),
			int(basis_walk["end"]), int(tail["basis_len_off"])])
	_expect("18.2 basis block: the declared byte length covers count + rows (@ %d = %d "
		% [int(tail["basis_block_bytes"]), int(basis_walk["end"])
		- int(tail["basis_block_off"])] + "bytes walked)",
		int(tail["basis_block_bytes"]) == int(basis_walk["end"])
			- int(tail["basis_block_off"]),
		"declared=%d walked=%d" % [int(tail["basis_block_bytes"]),
			int(basis_walk["end"]) - int(tail["basis_block_off"])])
	_expect("18.2 basis block: a world with NO card in play persists an EMPTY basis "
		+ "(0 rows) rather than a fabricated one",
		int(tail["basis_row_count"]) == 0, str(tail["basis_row_count"]))
	# The basis block is HASHED (plan 18.2): an unhashed persisted block would be one a
	# payload can rewrite undetected, so a flipped row byte must be caught by the state
	# hash -- never silently accepted. Both refusal layers are asserted: the basis
	# comparison (which runs first) and the hash.
	var basis_row_count: int = int(tail["basis_row_count"])
	var bad_basis_len: PackedByteArray = plain["pkid"].duplicate()
	# A length field that does not match the rows is a shape violation, refused by name.
	bad_basis_len.encode_u32(int(tail["basis_len_off"]),
		int(tail["basis_block_bytes"]) - 1)
	_refuse_pkid(target, "18.2 basis block: a byte length that does not match its rows "
		+ "is refused as a SHAPE error", bad_basis_len,
		"ideology_save_applied_basis_invalid")
	var bad_basis_count: PackedByteArray = plain["pkid"].duplicate()
	bad_basis_count.encode_u32(int(tail["basis_block_off"]), 1 << 20)
	_refuse_pkid(target, "18.2 basis block: a row count of 2^20 with no rows behind it "
		+ "is refused as a SHAPE error", bad_basis_count,
		"ideology_save_applied_basis_invalid")
	# NOTE: the two VALUE-level refusals (`ideology_save_applied_basis_mismatch`) need a
	# payload with a NON-EMPTY basis, which needs a SETTLED card. This world never ACKs
	# its equip, so they live in `ideology_save_basis_and_midmaterialize_test` instead --
	# one fixture for the block's shape, one for its content.
	# -- L23b: the plan 18.5 LOCAL SCALAR BASIS and the sample day -----
	#
	# The second variable-length block, and the one whose rows are NOT a function of the
	# card set: they are the numbers a card's program reads through `READ_METRIC`. Both
	# refusal layers are asserted here, because unlike the applied basis this block's
	# CONTENT check can fire on a payload whose card set is unchanged (a rewritten value).
	var scalar_len_off: int = int(tail["scalar_len_off"])
	var scalar_block_off: int = int(tail["scalar_block_off"])
	var scalar_block_bytes: int = int(tail["scalar_block_bytes"])
	var scalar_walk: Dictionary = _walk_scalar_block(plain["pkid"], scalar_block_off)
	_expect("18.5 scalar basis: walking its rows lands exactly on its own length field "
		+ "(@ %d)" % scalar_len_off,
		String(scalar_walk["error"]).is_empty()
			and int(scalar_walk["end"]) == scalar_len_off,
		"error=%s end=%d expected=%d" % [String(scalar_walk["error"]),
			int(scalar_walk["end"]), scalar_len_off])
	_expect("18.5 scalar basis: the declared byte length covers count + rows (@ %d = %d "
		% [scalar_block_bytes, int(scalar_walk["end"]) - scalar_block_off]
		+ "bytes walked)",
		scalar_block_bytes == int(scalar_walk["end"]) - scalar_block_off,
		"declared=%d walked=%d" % [scalar_block_bytes,
			int(scalar_walk["end"]) - scalar_block_off])
	# A world with an attached Effect catalog ALWAYS resolves the `ideology.scalar.*`
	# keys, so an empty block here would mean the values were never derived at all.
	_expect("18.5 scalar basis: a world with an Effect catalog persists the scalar "
		+ "VALUES (%d rows), all naming its own country handle, in strictly ascending "
		% int(scalar_walk["rows"]) + "metric order",
		int(scalar_walk["rows"]) >= 1
			and int(scalar_walk["foreign_handles"]) == 0
			and bool(scalar_walk["ascending"]),
		"rows=%d foreign=%d ascending=%s" % [int(scalar_walk["rows"]),
			int(scalar_walk["foreign_handles"]), str(scalar_walk["ascending"])])
	_expect("18.5 scalar basis: the sample day identity is present and in its domain "
		+ "(-1 = no projection installed yet, anything >= 0 = that day)",
		int(tail["sample_day"]) >= -1, str(tail["sample_day"]))
	print("[rob/18.5] scalar block: rows=%d %d bytes, sample_day=%d, first metric=%d "
		% [int(scalar_walk["rows"]), scalar_block_bytes, int(tail["sample_day"]),
			int(scalar_walk["first_metric"])]
		+ "value=%d nonzero=%d" % [int(scalar_walk["first_value"]),
			int(scalar_walk["nonzero"])])
	# THE BLOCK TRACKS CARD STATE, differentially: the ARMED payload has one card
	# equipped and the PLAIN one has none, so at least one scalar value must differ. This
	# is what separates "the values are re-derived from the rows" from "the values are a
	# static template copied into every payload".
	var armed_scalar_walk: Dictionary = _walk_scalar_block(armed["pkid"],
		int(_pkid_tail(armed["pkid"])["scalar_block_off"]))
	var scalar_diffs := 0
	var compare_rows: int = mini(int(scalar_walk["rows"]),
		int(armed_scalar_walk["rows"]))
	for index in range(compare_rows):
		var plain_off: int = scalar_block_off + 4 + index * PKID_SCALAR_ROW_BYTES
		var armed_off: int = int(_pkid_tail(armed["pkid"])["scalar_block_off"]) + 4 \
			+ index * PKID_SCALAR_ROW_BYTES
		if plain["pkid"].decode_s64(plain_off + 12) \
				!= armed["pkid"].decode_s64(armed_off + 12):
			scalar_diffs += 1
	_expect("18.5 scalar basis: equipping a card CHANGES the persisted values "
		+ "(PLAIN vs ARMED differ in %d rows)" % scalar_diffs,
		int(scalar_walk["rows"]) > 0
			and int(scalar_walk["rows"]) == int(armed_scalar_walk["rows"])
			and scalar_diffs >= 1,
		"plain_rows=%d armed_rows=%d diffs=%d" % [int(scalar_walk["rows"]),
			int(armed_scalar_walk["rows"]), scalar_diffs])
	# A VALUE the current catalogs cannot rebuild -> the CONTENT refusal, by name.
	var bad_scalar_value: PackedByteArray = plain["pkid"].duplicate()
	var scalar_value_off: int = int(scalar_walk["first_value_off"])
	bad_scalar_value.encode_u8(scalar_value_off,
		bad_scalar_value.decode_u8(scalar_value_off) ^ 0x01)
	_refuse_pkid(target, "18.5 scalar basis: a value the catalogs cannot rebuild is "
		+ "refused as a CONTENT error", bad_scalar_value,
		"ideology_save_scalar_basis_mismatch")
	# A block length that does not match its rows -> the SHAPE refusal.
	var bad_scalar_len: PackedByteArray = plain["pkid"].duplicate()
	bad_scalar_len.encode_u32(scalar_len_off, scalar_block_bytes - 1)
	_refuse_pkid(target, "18.5 scalar basis: a byte length that does not match its rows "
		+ "is refused as a SHAPE error", bad_scalar_len,
		"ideology_save_scalar_basis_invalid")
	# A count with no rows behind it. 20 bytes per row, so 2^20 rows cannot fit in the
	# remaining payload and the bound turns it into a shape error instead of a slow
	# truncation.
	var bad_scalar_count: PackedByteArray = plain["pkid"].duplicate()
	bad_scalar_count.encode_u32(scalar_block_off, 1 << 20)
	_refuse_pkid(target, "18.5 scalar basis: a row count of 2^20 with no rows behind it "
		+ "is refused as a SHAPE error", bad_scalar_count,
		"ideology_save_scalar_basis_invalid")
	# A metric id below the builder's own "unresolved" sentinel cannot describe a slab
	# slot, so it is a shape error too (and it breaks the ascending rule as well).
	var bad_metric: PackedByteArray = plain["pkid"].duplicate()
	bad_metric.encode_s32(scalar_block_off + 4 + 8, -1)
	_refuse_pkid(target, "18.5 scalar basis: metric id -1 in the first row is refused "
		+ "as a SHAPE error", bad_metric, "ideology_save_scalar_basis_invalid")
	# The sample day is in NO content comparison, so a rewrite of it can only be caught
	# by the state hash -- which is exactly what "it is hashed" means, asserted rather
	# than claimed.
	var bad_sample_day: PackedByteArray = plain["pkid"].duplicate()
	bad_sample_day.encode_s64(int(tail["sample_day_off"]), int(tail["sample_day"]) + 1007)
	_refuse_pkid(target, "18.5 sample day: a rewritten sample day (+1007) is caught by "
		+ "the STATE HASH", bad_sample_day, "ideology_save_state_hash_mismatch")
	# Below -1 is neither a real day nor the "no projection" sentinel.
	var neg_sample_day: PackedByteArray = plain["pkid"].duplicate()
	neg_sample_day.encode_s64(int(tail["sample_day_off"]), -2)
	_refuse_pkid(target, "18.5 sample day: -2 is not a day and not the 'no projection' "
		+ "sentinel, so it is refused as a SHAPE error", neg_sample_day,
		"ideology_save_scalar_basis_invalid")
	# -- 18.5 ATOMICITY: a refusal AFTER the block was parsed and committed ----
	#
	# The scalar record and the sample day are MEMBERS, assigned at the restore commit
	# point (exactly like the plan 18.2 basis) and put back by `rollback`. The damage
	# below is on the state hash, which the reader checks AFTER that commit point, so the
	# payload's block and day were already installed when the refusal happened -- which
	# is the only window in which a missing rollback entry would be visible.
	#
	# Non-vacuity is asserted, not assumed: the target has never restored, so its record
	# is EMPTY and its day is whatever its own rebuild stamped, while the payload carries
	# at least one row and a day 998 away from that.
	var atomic_report: Dictionary = target.get_ideology_report()
	var atomic_rows: int = int(atomic_report.get("local_scalar_basis_rows", -1))
	var atomic_value: int = int(atomic_report.get("local_scalar_basis_first_value", 0))
	var atomic_day: int = int(atomic_report.get("derived_basis_sample_day", -2))
	var atomic_capture: PackedByteArray = target.capture_ideology_state()
	var late_payload: PackedByteArray = plain["pkid"].duplicate()
	var late_day: int = int(tail["sample_day"]) + 998
	late_payload.encode_s64(int(tail["sample_day_off"]), late_day)
	late_payload.encode_u64(PKID_OFF_STATE_HASH,
		late_payload.decode_u64(PKID_OFF_STATE_HASH) ^ 1)
	var late_reason: String = _refuse_pkid(target,
		"18.5 atomicity: the state-hash-damaged payload is refused AFTER the scalar "
		+ "record and the sample day were committed", late_payload,
		"ideology_save_state_hash_mismatch")
	var after_atomic: Dictionary = target.get_ideology_report()
	_expect("18.5 atomicity: the payload really carried %d scalar rows and day %d while "
		% [int(scalar_walk["rows"]), late_day]
		+ "the target held %d rows / day %d, so the assignment was not a no-op"
		% [atomic_rows, atomic_day],
		int(scalar_walk["rows"]) >= 1 and int(scalar_walk["rows"]) != atomic_rows,
		"payload_rows=%d target_rows=%d payload_day=%d target_day=%d"
			% [int(scalar_walk["rows"]), atomic_rows, late_day, atomic_day])
	_expect("18.5 atomicity: the scalar record is back at its PRE-restore value "
		+ "(%d rows, first value %d) after the refusal" % [atomic_rows, atomic_value],
		int(after_atomic.get("local_scalar_basis_rows", -2)) == atomic_rows
			and int(after_atomic.get("local_scalar_basis_first_value", 0))
				== atomic_value,
		"rows %d->%d value %d->%d" % [atomic_rows,
			int(after_atomic.get("local_scalar_basis_rows", -2)), atomic_value,
			int(after_atomic.get("local_scalar_basis_first_value", 0))])
	_expect("18.5 atomicity: the sample day is back at its PRE-restore value (%d), not "
		% atomic_day
		+ "the payload's %d" % late_day,
		int(after_atomic.get("derived_basis_sample_day", -3)) == atomic_day,
		"%d->%d (payload said %d)" % [atomic_day,
			int(after_atomic.get("derived_basis_sample_day", -3)), late_day])
	_expect("18.5 atomicity: the whole PKID capture is BYTE-IDENTICAL after that "
		+ "refusal, so nothing else moved either",
		target.capture_ideology_state() == atomic_capture,
		"%d vs %d bytes, first diff @%d" % [
			target.capture_ideology_state().size(), atomic_capture.size(),
			_first_diff(target.capture_ideology_state(), atomic_capture)])
	print("[rob/18.5] atomicity: rows %d -> %d, day %d -> %d (payload offered %d/%d), "
		% [atomic_rows, int(after_atomic.get("local_scalar_basis_rows", -2)),
			atomic_day, int(after_atomic.get("derived_basis_sample_day", -3)),
			int(scalar_walk["rows"]), late_day]
		+ "reason=%s" % late_reason)
	# -- L-new: the plan 9.3 basis dates, and the pair validation ------
	# p.719 requires the save to carry confirmed_day / eligible_from_day so a load can
	# tell which projections are not eligible yet. Assert the block is really there and
	# that a legal pair reads back, then prove an ILLEGAL pair is refused.
	var basis_off: int = int(tail["basis_dates_off"])
	var basis_conf: int = plain["pkid"].decode_s64(basis_off)
	var basis_elig: int = plain["pkid"].decode_s64(basis_off + 8)
	_expect("9.3 basis dates: a never-settled world stores -1 / -1 (no projection yet)",
		basis_conf == -1 and basis_elig == -1,
		"confirmed=%d eligible=%d" % [basis_conf, basis_elig])
	# Plan 11.5: the execution-contract identity must be real (not a zero placeholder) and
	# must match what the runtime says it is. A zero here would mean the identity is
	# structural rather than computed -- which is exactly the state this replaced.
	var contract_off: int = int(tail["contract_off"])
	var contract_in_payload: int = plain["pkid"].decode_s64(contract_off)
	var contract_reported: int = int(target.get_ideology_report().get(
		"execution_contract_hash", 0))
	_expect("11.5 contract identity: the payload carries a non-zero execution contract",
		contract_in_payload != 0, str(contract_in_payload))
	_expect("11.5 contract identity: the payload's value is the runtime's own",
		contract_in_payload == contract_reported,
		"payload=%d runtime=%d" % [contract_in_payload, contract_reported])
	var skew_basis: PackedByteArray = plain["pkid"].duplicate()
	skew_basis.encode_s64(basis_off, 5)
	skew_basis.encode_s64(basis_off + 8, 9)
	_refuse_pkid(target, "9.3 basis dates: eligible != confirmed + 1 is refused",
		skew_basis, "ideology_save_basis_dates_invalid")
	var half_basis: PackedByteArray = plain["pkid"].duplicate()
	half_basis.encode_s64(basis_off, 5)
	half_basis.encode_s64(basis_off + 8, -1)
	_refuse_pkid(target, "9.3 basis dates: one side set and the other unset is refused",
		half_basis, "ideology_save_basis_dates_invalid")
	# -- L21 trailer --------------------------------------------------
	var bad_end: PackedByteArray = plain["pkid"].duplicate()
	var end_off: int = bad_end.size() - 1
	bad_end.encode_u8(end_off, bad_end.decode_u8(end_off) ^ 0xFF)
	_refuse_pkid(target, "L21 PKID SAVE_END trailer byte flipped (offset %d)"
		% end_off, bad_end, "ideology_save_truncated")
	# -- L22 state hash -----------------------------------------------
	var bad_hash: PackedByteArray = plain["pkid"].duplicate()
	bad_hash.encode_u64(PKID_OFF_STATE_HASH,
		bad_hash.decode_u64(PKID_OFF_STATE_HASH) ^ 1)
	_refuse_pkid(target, "L22 PKID state hash (low bit flipped)", bad_hash,
		"ideology_save_state_hash_mismatch")
	var off_points: int = int(layout["points_q16_off"])
	var bad_points: PackedByteArray = plain["pkid"].duplicate()
	bad_points.encode_s64(off_points, bad_points.decode_s64(off_points) + 1)
	_refuse_pkid(target, "L22 PKID country points +1 q16 (offset %d) -- shape is "
		% off_points + "legal, only the state hash can see it", bad_points,
		"ideology_save_state_hash_mismatch")
	var bad_handle: PackedByteArray = plain["pkid"].duplicate()
	var off_handle: int = int(layout["country_handle_off"])
	bad_handle.encode_u64(off_handle,
		bad_handle.decode_u64(off_handle) ^ (1 << 40))
	# NOTE ON WHICH LAYER ANSWERS (changed by schema 14, measured): the country handle
	# appears in EVERY §18.5 scalar row, so a corrupted handle no longer survives to the
	# state hash -- a reconstruction from the payload's own rows names the other country
	# and the pairing rule refuses it first. That is a MORE specific diagnosis for the
	# same corruption, not a weaker one: the byte is still refused by name, and the state
	# hash's coverage of the handle is still proven by the points case above (a
	# shape-legal field only the hash can see).
	_refuse_pkid(target, "18.5 pairing: a country handle bit 40 flip is caught by the "
		+ "scalar block's own handle pairing (before the state hash)", bad_handle,
		"ideology_save_scalar_basis_mismatch")
	# -- blind mid-payload corruption ---------------------------------
	var mid_off: int = int(plain["pkid"].size() / 2)
	var bad_mid: PackedByteArray = plain["pkid"].duplicate()
	bad_mid.encode_u8(mid_off, bad_mid.decode_u8(mid_off) ^ 0xFF)
	_refuse_pkid(target, "L22 PKID mid-payload byte flipped (offset %d of %d)"
		% [mid_off, plain["pkid"].size()], bad_mid,
		"ideology_save_state_hash_mismatch")

	print("")
	print("[rob] ===== PKID truncation (never a crash, never garbage) =====")
	# Lengths chosen to land on a DIFFERENT layer each time:
	#   0/1/4/8/20 -> the header read dies            L2 header_invalid
	#   40         -> exactly the header, count dies   L5 producer_count_invalid
	#   half       -> somewhere in the country row
	#   size-1..4  -> the trailer dies                 L21 truncated
	_refuse_pkid(target, "L2 PKID truncated to 0 bytes", PackedByteArray(),
		"ideology_save_header_invalid")
	_refuse_pkid(target, "L2 PKID truncated to 1 byte", plain["pkid"].slice(0, 1),
		"ideology_save_header_invalid")
	_refuse_pkid(target, "L2 PKID truncated to magic only (4 bytes)",
		plain["pkid"].slice(0, 4), "ideology_save_header_invalid")
	_refuse_pkid(target, "L2 PKID truncated to magic+schema (8 bytes)",
		plain["pkid"].slice(0, 8), "ideology_save_header_invalid")
	_refuse_pkid(target, "L2 PKID truncated to magic+schema+catalog (16 bytes)",
		plain["pkid"].slice(0, 16), "ideology_save_header_invalid")
	_refuse_pkid(target, "L2 PKID truncated mid last_day (20 bytes)",
		plain["pkid"].slice(0, 20), "ideology_save_header_invalid")
	_refuse_pkid(target, "L5 PKID truncated to exactly the header (40 bytes)",
		plain["pkid"].slice(0, PKID_HEADER_SIZE),
		"ideology_save_producer_count_invalid")
	# A cut at an ARBITRARY point must still be a refusal, never a crash or garbage.
	# The layer that fires is MEASURED rather than predicted: the payload's length is a
	# function of the catalog (bit sets, offer ids, and since v13/v14 two variable-length
	# basis blocks), so "half" moves whenever content grows and hard-coding which field
	# it lands in would encode a fact that is not a constant.
	var half := int(plain["pkid"].size() / 2)
	_refuse_pkid(target, "L-any PKID truncated to %d of %d bytes (an arbitrary cut)"
		% [half, plain["pkid"].size()], plain["pkid"].slice(0, half), "")
	# ... and ONE cut derived from the layout, so a named layer is pinned: three entries
	# into the 16-slot history ring. The ring's offset is computed from the fixed country
	# row, never guessed (`_pkid_layout`'s `history_q16_off`).
	var ring_off: int = int(layout["history_q16_off"])
	var ring_cut: int = ring_off + 3 * 8
	_refuse_pkid(target, "L9 PKID truncated %d entries into the point-history ring "
		% 3 + "(@ %d of %d bytes)" % [ring_cut, plain["pkid"].size()],
		plain["pkid"].slice(0, ring_cut), "ideology_save_point_history_invalid")
	for drop in [1, 2, 3, 4]:
		var cut: int = plain["pkid"].size() - drop
		_refuse_pkid(target, "L21 PKID truncated to size-%d (%d bytes)"
			% [drop, cut], plain["pkid"].slice(0, cut),
			"ideology_save_truncated")

	print("")
	print("[rob] ===== PKEF refusals (effect_runtime.cpp:7394-8077) =====")
	# -- K2/K3 magic ---------------------------------------------------
	var pkef_empty: PackedByteArray = PackedByteArray()
	_refuse_pkef(target, "K2 PKEF truncated to 0 bytes", pkef_empty, "pkef_truncated")
	_refuse_pkef(target, "K2 PKEF truncated to 1 byte", plain["pkef"].slice(0, 1),
		"pkef_truncated")
	_refuse_pkef(target, "K2 PKEF truncated to magic only (4 bytes)",
		plain["pkef"].slice(0, 4), "pkef_truncated")
	_refuse_pkef(target, "K4 PKEF truncated to magic+schema (8 bytes) -- the "
		+ "protocol read reports catalog_hash_mismatch, not pkef_truncated",
		plain["pkef"].slice(0, 8), "catalog_hash_mismatch")
	_refuse_pkef(target, "K5 PKEF truncated after protocol (12 bytes)",
		plain["pkef"].slice(0, 12), "catalog_hash_mismatch")
	_refuse_pkef(target, "K6 PKEF truncated after the catalog hash (20 bytes)",
		plain["pkef"].slice(0, 20), "pkef_instances_invalid")
	# Half of the PLAIN payload is 152, which is exactly where the era-reward
	# block's `status` field is read (`effect_runtime.cpp:7963`), so the whole
	# truncated stream is consumed by the era-reward tail.
	var pkef_half := int(plain["pkef"].size() / 2)
	_refuse_pkef(target, "K17 PKEF truncated to %d of %d bytes (inside the "
		% [pkef_half, plain["pkef"].size()] + "era-reward block)",
		plain["pkef"].slice(0, pkef_half), "pkef_era_reward_truncated")
	for drop in [1, 2, 3, 4]:
		var pcut: int = plain["pkef"].size() - drop
		_refuse_pkef(target, "K18 PKEF truncated to size-%d (%d bytes)"
			% [drop, pcut], plain["pkef"].slice(0, pcut),
			"pkef_end_marker_missing")
	# -- K3 magic ------------------------------------------------------
	var pkef_bad_magic: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_magic.encode_u8(PKEF_OFF_MAGIC,
		pkef_bad_magic.decode_u8(PKEF_OFF_MAGIC) ^ 0xFF)
	_refuse_pkef(target, "K3 PKEF wrong magic (offset 0 flipped)", pkef_bad_magic,
		"pkef_header_incompatible")
	# -- K4 schema, old and future ------------------------------------
	var pkef_old: PackedByteArray = plain["pkef"].duplicate()
	pkef_old.encode_s32(PKEF_OFF_SCHEMA, PKEF_SCHEMA - 1)
	_refuse_pkef(target, "K4 PKEF OLD schema (%d -> %d)"
		% [PKEF_SCHEMA, PKEF_SCHEMA - 1], pkef_old, "pkef_schema_unsupported")
	var pkef_future: PackedByteArray = plain["pkef"].duplicate()
	pkef_future.encode_s32(PKEF_OFF_SCHEMA, PKEF_SCHEMA + 1)
	_refuse_pkef(target, "K4 PKEF FUTURE schema (%d -> %d)"
		% [PKEF_SCHEMA, PKEF_SCHEMA + 1], pkef_future, "pkef_schema_unsupported")
	# -- K5 protocol / catalog -----------------------------------------
	var pkef_bad_protocol: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_protocol.encode_s32(PKEF_OFF_PROTOCOL, PKEF_PROTOCOL + 1)
	_refuse_pkef(target, "K5 PKEF protocol (%d -> %d)"
		% [PKEF_PROTOCOL, PKEF_PROTOCOL + 1], pkef_bad_protocol,
		"catalog_hash_mismatch")
	var pkef_bad_catalog: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_catalog.encode_u64(PKEF_OFF_CATALOG,
		pkef_bad_catalog.decode_u64(PKEF_OFF_CATALOG) ^ 1)
	_refuse_pkef(target, "K5 PKEF catalog hash (low bit flipped)", pkef_bad_catalog,
		"catalog_hash_mismatch")
	# -- K6 cursors ----------------------------------------------------
	var pkef_bad_instance_count: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_instance_count.encode_u32(PKEF_OFF_INSTANCE_COUNT, 1 << 24)
	_refuse_pkef(target, "K6 PKEF instance count = 2^24", pkef_bad_instance_count,
		"pkef_instances_invalid")
	var pkef_bad_next_tx: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_next_tx.encode_s64(PKEF_OFF_NEXT_TRANSACTION, 0)
	_refuse_pkef(target, "K6 PKEF next transaction id = 0", pkef_bad_next_tx,
		"pkef_runtime_cursor_invalid")
	var pkef_bad_acked: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_acked.encode_s64(PKEF_OFF_ACKED_TRANSACTION, 1 << 40)
	_refuse_pkef(target, "K6 PKEF acked transaction id ahead of the next one",
		pkef_bad_acked, "pkef_runtime_cursor_invalid")
	# -- K11 transaction table / K16 bindings --------------------------
	# Both cases raise a COUNT with no rows behind it. The count read succeeds and
	# the reader then consumes the era-reward bytes as if they were a row, so the
	# rejection comes from the row's identity check rather than a short read. The
	# code is recorded as measured -- it is still the layer's own code, not a
	# generic one.
	var pkef_bad_tx_count: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_tx_count.encode_u32(PKEF_OFF_TRANSACTION_COUNT, 1)
	_refuse_pkef(target, "K11 PKEF transaction count = 1 with no row behind it",
		pkef_bad_tx_count, "pkef_transaction_identity_invalid")
	var pkef_bad_binding_count: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_binding_count.encode_u32(PKEF_OFF_BINDING_COUNT, 1)
	_refuse_pkef(target, "K16 PKEF external binding count = 1 with no row behind "
		+ "it", pkef_bad_binding_count, "pkef_external_binding_invalid")
	# -- K17 era reward: the one fixed-offset region past the counts ----
	# Precondition, asserted rather than assumed: with no instance and no
	# transaction row the era-reward block really does start at
	# PKEF_ERA_REWARD_OFFSET, which is what makes the next two offsets the fields
	# the reader reads (`effect_runtime.cpp:7954-7983`).
	_expect("K17 PKEF PLAIN layout: no instance row and no transaction row, so the "
		+ "era-reward block starts at offset %d" % PKEF_ERA_REWARD_OFFSET,
		plain["pkef"].decode_u32(PKEF_OFF_INSTANCE_COUNT) == 0
			and plain["pkef"].decode_u32(PKEF_OFF_TRANSACTION_COUNT) == 0,
		"instances=%d transactions=%d" % [
			plain["pkef"].decode_u32(PKEF_OFF_INSTANCE_COUNT),
			plain["pkef"].decode_u32(PKEF_OFF_TRANSACTION_COUNT)])
	var pkef_bad_status: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_status.encode_s32(PKEF_OFF_ERA_STATUS, 9)
	_refuse_pkef(target, "K17 PKEF era-reward status = 9 (offset %d, mid-payload)"
		% PKEF_OFF_ERA_STATUS, pkef_bad_status, "pkef_era_reward_identity_invalid")
	var pkef_bad_next_plan: PackedByteArray = plain["pkef"].duplicate()
	pkef_bad_next_plan.encode_s64(PKEF_OFF_ERA_NEXT_PLAN_ID, 0)
	_refuse_pkef(target, "K17 PKEF era-reward next plan id = 0 (offset %d)"
		% PKEF_OFF_ERA_NEXT_PLAN_ID, pkef_bad_next_plan,
		"pkef_era_reward_identity_invalid")
	# -- K18 trailer ---------------------------------------------------
	var pkef_bad_end: PackedByteArray = plain["pkef"].duplicate()
	var pkef_end_off: int = pkef_bad_end.size() - 1
	pkef_bad_end.encode_u8(pkef_end_off,
		pkef_bad_end.decode_u8(pkef_end_off) ^ 0xFF)
	_refuse_pkef(target, "K18 PKEF SAVE_END trailer byte flipped (offset %d)"
		% pkef_end_off, pkef_bad_end, "pkef_end_marker_missing")

	# ==================================================================
	# D. THE CONTROL: a valid payload still restores, byte for byte
	# ==================================================================
	print("")
	print("[rob] ===== control: the untouched payloads restore =====")
	# The target starts byte-identical to the payload (asserted above), so make it
	# DRIFT first: otherwise "the restore worked" would only mean "nothing moved".
	# A second ideology day moves the last day, the points ledger and the history
	# ring, so a successful restore has to put all three back.
	_run_one_ideology_day(target, 1, "target/day1")
	var drifted: PackedByteArray = target.capture_ideology_state()
	_expect("CONTROL: the target really drifted before the control restore (its "
		+ "last day is now 1, not the payload's 0)", drifted != plain["pkid"],
		"first diff @%d" % _first_diff(drifted, plain["pkid"]))
	var effect_result: Dictionary = target.restore_effect_state(plain["pkef"])
	_expect("CONTROL: PKEF restores into the freshly built runtime",
		bool(effect_result.get("ok", false)),
		"reason=%s" % String(effect_result.get("reason", "")))
	var ideology_result: Dictionary = target.restore_ideology_state(plain["pkid"])
	_expect("CONTROL: PKID restores into the freshly built runtime",
		bool(ideology_result.get("ok", false)),
		"reason=%s" % String(ideology_result.get("reason", "")))
	_expect("CONTROL: the restore echoes the state hash stored in the payload",
		int(ideology_result.get("state_hash", 0))
			== plain["pkid"].decode_u64(PKID_OFF_STATE_HASH),
		"echo=%s field=%s" % [str(ideology_result.get("state_hash", "?")),
			str(plain["pkid"].decode_u64(PKID_OFF_STATE_HASH))])
	_expect("CONTROL: PKID re-captured after the restore is BYTE-IDENTICAL to the "
		+ "payload it came from (writer == reader)",
		target.capture_ideology_state() == plain["pkid"],
		"%d vs %d bytes, first diff @%d" % [
			target.capture_ideology_state().size(), plain["pkid"].size(),
			_first_diff(target.capture_ideology_state(), plain["pkid"])])
	# -- §18.5: the successful restore really did ASSIGN the two members ----
	#
	# The atomicity case above proved they are put BACK on a refusal; this proves they are
	# put IN on success, so "unchanged" there cannot mean "never assigned anywhere".
	var adopted_report: Dictionary = target.get_ideology_report()
	_expect("CONTROL: the restored runtime holds the payload's %d scalar rows (its own "
		% int(scalar_walk["rows"]) + "record was empty before the load)",
		int(adopted_report.get("local_scalar_basis_rows", -1))
			== int(scalar_walk["rows"]),
		"runtime=%s payload=%d" % [str(adopted_report.get("local_scalar_basis_rows", "?")),
			int(scalar_walk["rows"])])
	_expect("CONTROL: the restored runtime reports the payload's sample day (%d)"
		% int(tail["sample_day"]),
		int(adopted_report.get("derived_basis_sample_day", -2))
			== int(tail["sample_day"]),
		"runtime=%s payload=%s" % [
			str(adopted_report.get("derived_basis_sample_day", "?")),
			str(tail["sample_day"])])
	_expect("CONTROL: PKEF re-captured after the restore is BYTE-IDENTICAL to the "
		+ "payload it came from", target.capture_effect_state() == plain["pkef"],
		"%d vs %d bytes, first diff @%d" % [
			target.capture_effect_state().size(), plain["pkef"].size(),
			_first_diff(target.capture_effect_state(), plain["pkef"])])
	var target_business: Dictionary = target.get_ideology_business_state()
	for key in ["hash", "points", "baseline", "history", "draw", "bits", "offer",
			"ideas", "committed_day", "catalog_hash"]:
		_expect("CONTROL: the restored business section `%s` matches the world the "
			% key + "payload was captured from", int(target_business.get(key, -1))
				== int(plain_business.get(key, -2)),
			"%s vs %s" % [str(target_business.get(key, "?")),
				str(plain_business.get(key, "?"))])
	_expect("CONTROL: the restored ideology snapshot carries the same points the "
		+ "source snapshot reports",
		int(target.get_ideology_snapshot(target_handle).get("ideology_points_q16",
			-1)) == int(plain_snapshot.get("ideology_points_q16", -2)),
		"%s vs %s" % [str(target.get_ideology_snapshot(target_handle).get(
			"ideology_points_q16", "?")),
			str(plain_snapshot.get("ideology_points_q16", "?"))])
	for key in ["locations", "levels", "idea_ids", "understanding_q16"]:
		_expect("CONTROL: the restored snapshot field `%s` is identical to the "
			% key + "source's", str(target.get_ideology_snapshot(
				target_handle).get(key, "?")) == str(plain_snapshot.get(key, "??")),
			"%s vs %s" % [str(target.get_ideology_snapshot(target_handle).get(
				key, "?")), str(plain_snapshot.get(key, "??"))])

	# ==================================================================
	# E. L26: the wrong ORDER -- PKID before PKEF must be refused
	# ==================================================================
	print("")
	print("[rob] ===== L26 ordering: PKID without PKEF =====")
	var effect_before_wrong_order: PackedByteArray = target.capture_effect_state()
	var wrong_order: Dictionary = target.restore_ideology_state(armed["pkid"])
	_expect("L26: restoring the EQUIPPED PKID without PKEF is REFUSED",
		not bool(wrong_order.get("ok", true)),
		"ok=true reason=%s" % String(wrong_order.get("reason", "")))
	_expect("L26: the refusal reason is "
		+ "`ideology_effect_binding_missing_or_mismatched`",
		String(wrong_order.get("reason", ""))
			== "ideology_effect_binding_missing_or_mismatched",
		"observed=%s" % String(wrong_order.get("reason", "")))
	_expect("L26: the refused out-of-order restore leaves the Effect runtime "
		+ "byte-identical",
		target.capture_effect_state() == effect_before_wrong_order,
		"first diff @%d" % _first_diff(target.capture_effect_state(),
			effect_before_wrong_order))
	_expect("L26: the refused out-of-order restore leaves the ideology runtime on "
		+ "the CONTROL payload (not the equipped one)",
		target.capture_ideology_state() == plain["pkid"],
		"first diff @%d" % _first_diff(target.capture_ideology_state(),
			plain["pkid"]))
	# The same two payloads in the production order: PKEF first, then PKID.
	var armed_effect_result: Dictionary = target.restore_effect_state(armed["pkef"])
	_expect("L26: the same payload's PKEF restores first",
		bool(armed_effect_result.get("ok", false)),
		"reason=%s" % String(armed_effect_result.get("reason", "")))
	_expect("L26: PKEF now carries the equipped card's external binding",
		int(target.get_effect_report().get("external_bindings", 0)) >= 1,
		str(target.get_effect_report().get("external_bindings", "?")))
	var armed_result: Dictionary = target.restore_ideology_state(armed["pkid"])
	_expect("L26: PKID restores once PKEF has landed (the ordering is the whole "
		+ "difference)", bool(armed_result.get("ok", false)),
		"reason=%s" % String(armed_result.get("reason", "")))
	var armed_snapshot: Dictionary = target.get_ideology_snapshot(target_handle)
	_expect("L26: the restored card is ACTIVE (a non-zero location slot)",
		_active_locations(armed_snapshot) > 0,
		str(armed_snapshot.get("locations", "?")))
	var rearmed: PackedByteArray = target.capture_ideology_state()
	_expect("L26: the EQUIPPED PKID also round-trips byte for byte",
		rearmed == armed["pkid"], "%d vs %d bytes, first diff @%d"
		% [rearmed.size(), armed["pkid"].size(),
			_first_diff(rearmed, armed["pkid"])])
	var armed_business: Dictionary = target.get_ideology_business_state()
	_expect("L26: the equipped business hash matches the source world",
		int(armed_business.get("hash", 0)) == int(source_business.get("hash", -1)),
		"%s vs %s" % [str(armed_business.get("hash", "?")),
			str(source_business.get("hash", "?"))])

	# THE MIRROR OF THE MISSING BINDING. Now the Effect side holds a live
	# transaction for this country and the payload does not list it. That is just
	# as incoherent as PKID without PKEF, and `verify_external_pending_transactions_pod`
	# (`effect_runtime.cpp:2738-2750`) refuses it; the error travels out verbatim
	# through `fail(transaction_error)` (:6828).
	var stale: Dictionary = target.restore_ideology_state(plain["pkid"])
	_expect("L27: a PKID payload that does NOT list the Effect side's live "
		+ "transaction is REFUSED", not bool(stale.get("ok", true)), "ok=true")
	_expect("L27: the refusal carries the Effect side's own reason "
		+ "`effect_external_pending_transaction_unknown`",
		String(stale.get("reason", ""))
			== "effect_external_pending_transaction_unknown",
		"observed=%s" % String(stale.get("reason", "")))
	_expect("L27: the refused restore leaves the card equipped exactly as the "
		+ "restored payload said",
		str(target.get_ideology_snapshot(target_handle).get("locations", "?"))
			== str(armed_snapshot.get("locations", "??")),
		"%s vs %s" % [str(target.get_ideology_snapshot(target_handle).get(
			"locations", "?")), str(armed_snapshot.get("locations", "??"))])
	# Clear the Effect side again: the coverage probes below must measure the
	# header fields, not this ordering rule.
	var cleared: Dictionary = target.restore_effect_state(plain["pkef"])
	_expect("L27: the unequipped Effect payload restores again, clearing the live "
		+ "transaction", bool(cleared.get("ok", false)),
		"reason=%s" % String(cleared.get("reason", "")))

	# ==================================================================
	# F. WHAT IS NOT COVERED (measured, then printed as a finding)
	# ==================================================================
	print("")
	print("[rob] ===== coverage gaps of the two integrity schemes =====")
	# `compute_state_hash()` (:6359-6392) walks `_countries` only. `last_day`
	# (:6398) and `submit_order` (:6399) sit in the header and are restored
	# verbatim (:6728-6729), so nothing can see a change there.
	var injected_day: int = plain["pkid"].decode_s64(PKID_OFF_LAST_DAY) + 1007
	var day_payload: PackedByteArray = plain["pkid"].duplicate()
	day_payload.encode_s64(PKID_OFF_LAST_DAY, injected_day)
	var day_result: Dictionary = target.restore_ideology_state(day_payload)
	var day_accepted: bool = bool(day_result.get("ok", false))
	var adopted_day: int = int(
		target.get_ideology_business_state().get("committed_day", -999))
	print("[rob/gap] PKID last_day %d -> %d: ok=%s reason=%s adopted_committed_day=%d"
		% [injected_day - 1007, injected_day, str(day_accepted),
			String(day_result.get("reason", "")), adopted_day])
	if day_accepted and adopted_day == injected_day:
		_finding("PKID `last_day` (offset %d) is OUTSIDE compute_state_hash(): "
			% PKID_OFF_LAST_DAY + "a payload with the day rewritten from %d to %d "
			% [injected_day - 1007, injected_day]
			+ "restores with ok=true and the runtime ADOPTS the injected day")
	_expect("FINDING-DOC: the injected `last_day` case is REFUSED or the runtime "
		+ "adopts it verbatim (both outcomes are recorded, neither hides)",
		(not day_accepted) or adopted_day == injected_day,
		"accepted=%s adopted=%s injected=%d" % [str(day_accepted),
			str(adopted_day), injected_day])
	var injected_order: int = plain["pkid"].decode_u64(PKID_OFF_SUBMIT_ORDER) + 1007
	var order_payload: PackedByteArray = plain["pkid"].duplicate()
	order_payload.encode_u64(PKID_OFF_SUBMIT_ORDER, injected_order)
	var order_result: Dictionary = target.restore_ideology_state(order_payload)
	print("[rob/gap] PKID submit_order %d -> %d: ok=%s reason=%s"
		% [injected_order - 1007, injected_order,
			str(bool(order_result.get("ok", false))),
			String(order_result.get("reason", ""))])
	if bool(order_result.get("ok", false)):
		_finding("PKID `submit_order` (offset %d) is OUTSIDE "
			% PKID_OFF_SUBMIT_ORDER + "compute_state_hash(): a rewritten value "
			+ "restores with ok=true and is not observable through any public API")
	_expect("FINDING-DOC: the injected `submit_order` case is REFUSED or accepted "
		+ "(recorded either way)",
		bool(order_result.get("ok", false))
			or String(order_result.get("reason", "")) != "",
		"ok=%s reason=%s" % [str(order_result.get("ok", "?")),
			String(order_result.get("reason", ""))])
	# PKEF has no whole-payload hash at all, and `current_day` (:7418) is only
	# bounds-checked at -1.
	var injected_effect_day: int = plain["pkef"].decode_s64(PKEF_OFF_CURRENT_DAY) + 1007
	var effect_day_payload: PackedByteArray = plain["pkef"].duplicate()
	effect_day_payload.encode_s64(PKEF_OFF_CURRENT_DAY, injected_effect_day)
	var effect_day_result: Dictionary = target.restore_effect_state(effect_day_payload)
	var effect_day_accepted: bool = bool(effect_day_result.get("ok", false))
	var adopted_effect_day: int = int(
		target.get_effect_report().get("current_day", -999))
	print("[rob/gap] PKEF current_day %d -> %d: ok=%s reason=%s adopted_day=%d"
		% [injected_effect_day - 1007, injected_effect_day,
			str(effect_day_accepted), String(effect_day_result.get("reason", "")),
			adopted_effect_day])
	if effect_day_accepted and adopted_effect_day == injected_effect_day:
		_finding("PKEF has no state hash and `current_day` (offset %d) is only "
			% PKEF_OFF_CURRENT_DAY + "bounds-checked at -1: a rewritten day "
			+ "(%d -> %d) restores with ok=true and becomes the runtime's day"
			% [injected_effect_day - 1007, injected_effect_day])
	_expect("FINDING-DOC: the injected PKEF `current_day` case is REFUSED or the "
		+ "runtime adopts it verbatim (recorded either way)",
		(not effect_day_accepted) or adopted_effect_day == injected_effect_day,
		"accepted=%s adopted=%s injected=%d" % [str(effect_day_accepted),
			str(adopted_effect_day), injected_effect_day])

	# ==================================================================
	# G. BREADTH: a sampled single-byte sweep, no crash, measure the gaps
	# ==================================================================
	print("")
	print("[rob] ===== sampled single-byte sweep (every 8th byte) =====")
	# The cases above name the layers. This sweep is the breadth check behind
	# "never a crash, never accepted with garbage": one corrupted byte at a time
	# across the whole stream. Neither format promises to catch EVERY byte -- PKID
	# hashes `_countries` only, PKEF has no hash at all -- so the accepted offsets
	# are MEASURED and reported instead of being asserted away. What IS asserted is
	# that each attempt produces a diagnosable answer and that the runtime still
	# takes the pristine payload afterwards.
	_sweep(target, "PKID", plain["pkid"], true)
	_sweep(target, "PKEF", plain["pkef"], false)
	_finish()


# =====================================================================
# ABI / field layout
# =====================================================================

## Asserts the PKID header field by field against the runtime's own numbers.
##
## Reading a field at a fixed offset is only meaningful if the value there is
## the field the writer claims it is, so every offset is cross-checked against a
## public report of the same number. `catalog_hash` and `committed_day` come from
## `get_ideology_business_state()` (`world_ext_ideology.cpp:690-692`, fed by
## `ideology_runtime.cpp:5328-5330`), and the first country row's handle from
## `get_country_cell_summary`.
##
## Returns the derived offsets so the corruption cases can address the fields by
## name instead of by magic number.
func _expect_pkid_abi(bytes: PackedByteArray, ext: Object, handle: int,
		tag: String) -> Dictionary:
	_expect("%s: PKID ABI: the payload is at least one header long (%d bytes)"
		% [tag, PKID_HEADER_SIZE], bytes.size() >= PKID_HEADER_SIZE,
		"%d bytes" % bytes.size())
	if bytes.size() < PKID_HEADER_SIZE:
		return {}
	_expect("%s: PKID ABI: u32 @ 0 is the PKID magic 0x%08X" % [tag, PKID_MAGIC],
		bytes.decode_u32(PKID_OFF_MAGIC) == PKID_MAGIC,
		"0x%08X" % bytes.decode_u32(PKID_OFF_MAGIC))
	_expect("%s: PKID ABI: i32 @ 4 is schema version %d" % [tag, PKID_SCHEMA],
		bytes.decode_s32(PKID_OFF_SCHEMA) == PKID_SCHEMA,
		str(bytes.decode_s32(PKID_OFF_SCHEMA)))
	var business: Dictionary = ext.get_ideology_business_state()
	_expect("%s: PKID ABI: u64 @ 8 is the catalog hash the runtime reports"
		% tag, bytes.decode_u64(PKID_OFF_CATALOG)
			== int(business.get("catalog_hash", 0)),
		"payload=%s report=%s" % [str(bytes.decode_u64(PKID_OFF_CATALOG)),
			str(business.get("catalog_hash", "?"))])
	_expect("%s: PKID ABI: i64 @ 16 is the last day the business state reports"
		% tag, bytes.decode_s64(PKID_OFF_LAST_DAY)
			== int(business.get("committed_day", -999)),
		"payload=%s report=%s" % [str(bytes.decode_s64(PKID_OFF_LAST_DAY)),
			str(business.get("committed_day", "?"))])
	var layout: Dictionary = _pkid_layout(bytes)
	_expect("%s: PKID ABI: u64 @ 40 is the producer high-watermark count (%d)"
		% [tag, int(layout["producer_count"])],
		bytes.decode_u64(PKID_OFF_PRODUCER_COUNT) < 1024,
		str(bytes.decode_u64(PKID_OFF_PRODUCER_COUNT)))
	_expect("%s: PKID ABI: u8 @ %d is the worker_origin flag, and it is 0 for a "
		% [tag, int(layout["worker_origin_off"])]
		+ "main-thread world", bytes.decode_u8(int(layout["worker_origin_off"])) == 0,
		str(bytes.decode_u8(int(layout["worker_origin_off"]))))
	_expect("%s: PKID ABI: u64 @ %d is the country count, and this world has 1"
		% [tag, int(layout["country_count_off"])],
		bytes.decode_u64(int(layout["country_count_off"])) == 1,
		str(bytes.decode_u64(int(layout["country_count_off"]))))
	_expect("%s: PKID ABI: the first country row's handle (@ %d) is the world's "
		% [tag, int(layout["country_handle_off"])] + "own country handle",
		bytes.decode_u64(int(layout["country_handle_off"])) == handle,
		"payload=%s runtime=%d" % [
			str(bytes.decode_u64(int(layout["country_handle_off"]))), handle])
	var report: Dictionary = ext.get_ideology_report()
	_expect("%s: PKID ABI: the row's points (@ %d) are a signed q16 balance"
		% [tag, int(layout["points_q16_off"])],
		bytes.decode_s64(int(layout["points_q16_off"])) >= 0,
		str(bytes.decode_s64(int(layout["points_q16_off"]))))
	print("[rob/%s] PKID %d bytes, header=%d, producer rows=%d, country row @ %d, "
		% [tag, bytes.size(), PKID_HEADER_SIZE, int(layout["producer_count"]),
			int(layout["country_row_off"])]
		+ "last_day=%d state_hash=%d" % [bytes.decode_s64(PKID_OFF_LAST_DAY),
			bytes.decode_u64(PKID_OFF_STATE_HASH)])
	_expect("%s: PKID carries a non-zero state hash (the layer L22 compares "
		% tag + "against)", bytes.decode_u64(PKID_OFF_STATE_HASH) != 0,
		"%d" % bytes.decode_u64(PKID_OFF_STATE_HASH))
	if report.has("pending_commands"):
		print("[rob/%s] runtime pending_commands=%s pending_transitions=%s"
			% [tag, str(report.get("pending_commands", "?")),
				str(report.get("pending_transitions", "?"))])
	return layout


## Derives every PKID offset from the stream's own high-watermark count, so the
## corruption cases address fields by name. `ideology_runtime.cpp:6397-6422`
## writes, in order: 40-byte header, u64 row count, 12 bytes per row (i32 id +
## i64 sequence), u64 points_revision_seen, u8 worker_origin, u64 country count,
## then the country row (u64 handle, i64 points, i32 era, u64 rng, ...).
func _pkid_layout(bytes: PackedByteArray) -> Dictionary:
	var producer_count: int = int(bytes.decode_u64(PKID_OFF_PRODUCER_COUNT))
	var cursor: int = PKID_OFF_PRODUCER_COUNT + 8 + producer_count * 12
	var out := {
		"producer_count": producer_count,
		"points_revision_off": cursor,
		"worker_origin_off": cursor + 8,
		"country_count_off": cursor + 9,
	}
	var row: int = cursor + 17
	out["country_row_off"] = row
	out["country_handle_off"] = row
	out["points_q16_off"] = row + 8
	out["unlocked_era_off"] = row + 16
	out["rng_state_off"] = row + 20
	# The 16-entry point-history ring, derived from the WRITER's own field order
	# (`ideology_runtime.cpp` capture): handle 8, points 8, era 4, rng 8, draw_sequence 8,
	# free_draws 2, points_revision 8, baseline_ready 1, history_count 1, history_head 1,
	# baseline_population 8, baseline_buildings 8, lifetime_points 8, trade_paid_day 8,
	# then the six split ledger fields (8+8+8+4+4+8+8 = 48) = 129 bytes before
	# `history_q16[0]`. Changing a field above the ring must change this sum, which is
	# why it is written as a sum and not as 129.
	const COUNTRY_ROW_HISTORY_OFF := 8 + 8 + 4 + 8 + 8 + 2 + 8 + 1 + 1 + 1 + 8 + 8 \
		+ 8 + 8 + 8 + 8 + 8 + 4 + 4 + 8 + 8
	out["history_q16_off"] = row + COUNTRY_ROW_HISTORY_OFF
	return out


## Derives the PKID TAIL from the END of the payload, one field at a time.
##
## Everything after the country rows is variable-length (bit sets, offer ids, the
## history ring, the command table, and since v13/v14 the plan 18.2 applied-basis block
## and the plan 18.5 scalar-basis block), so addressing it from the FRONT means
## re-implementing the whole reader. The tail is fixed-order and ends with the 4-byte
## SAVE_END, so it is derived from the END -- every step using a named constant, never a
## literal.
##
## Layout, byte by byte from the end (v14):
##   size-4                        u32 SAVE_END
##   size-12                       u64 execution contract
##   size-28                       i64 confirmed_day, then i64 eligible_from_day @ size-20
##   size-36                       i64 sample day (plan 18.5 identity)
##   size-40                       u32 scalar-basis block length (count field + rows)
##   that offset - length          the scalar block: u32 row count, then 20-byte rows
##   block start - 4               u32 applied-basis block length (count field + rows)
##   that offset - length          the applied block: u32 row count, then the rows
##   block start - 8               u64 pending command count
##
## The two plan-18.5 fields were inserted IN FRONT of the dates, so the dates, the
## contract and the trailer keep the exact distance from `size` that v13 gave them --
## which is why the eligibility fixture did not have to move a single offset.
func _pkid_tail(bytes: PackedByteArray) -> Dictionary:
	var size: int = bytes.size()
	var out := {"size": size}
	var end_off: int = size - 4
	out["end_off"] = end_off
	var contract_off: int = end_off - PKID_CONTRACT_BYTES
	out["contract_off"] = contract_off
	var dates_off: int = contract_off - PKID_BASIS_DATES_BYTES
	out["basis_dates_off"] = dates_off
	var sample_day_off: int = dates_off - PKID_SAMPLE_DAY_BYTES
	out["sample_day_off"] = sample_day_off
	out["sample_day"] = 0
	var scalar_len_off: int = sample_day_off - PKID_SCALAR_LEN_BYTES
	out["scalar_len_off"] = scalar_len_off
	out["scalar_block_bytes"] = -1
	out["scalar_block_off"] = -1
	out["scalar_row_count"] = -1
	out["basis_len_off"] = -1
	out["basis_block_bytes"] = -1
	out["basis_block_off"] = -1
	out["basis_row_count"] = -1
	out["command_count_off"] = -1
	if scalar_len_off < PKID_HEADER_SIZE:
		return out
	out["sample_day"] = int(bytes.decode_s64(sample_day_off))
	var scalar_bytes: int = int(bytes.decode_u32(scalar_len_off))
	out["scalar_block_bytes"] = scalar_bytes
	var scalar_off: int = scalar_len_off - scalar_bytes
	out["scalar_block_off"] = scalar_off
	if scalar_bytes >= 4 and scalar_off >= PKID_HEADER_SIZE:
		out["scalar_row_count"] = int(bytes.decode_u32(scalar_off))
	else:
		return out
	var basis_len_off: int = scalar_off - PKID_BASIS_LEN_BYTES
	out["basis_len_off"] = basis_len_off
	if basis_len_off < PKID_HEADER_SIZE:
		return out
	var basis_bytes: int = int(bytes.decode_u32(basis_len_off))
	out["basis_block_bytes"] = basis_bytes
	var basis_off: int = basis_len_off - basis_bytes
	out["basis_block_off"] = basis_off
	out["command_count_off"] = basis_off - 8
	if basis_bytes >= 4 and basis_off >= PKID_HEADER_SIZE:
		out["basis_row_count"] = int(bytes.decode_u32(basis_off))
	return out


## Walks the plan-18.5 scalar block from its start, one row at a time.
##
## Returns the offset just past the last row so the caller can prove the block's own
## declared length is the TRUTH about its contents. `first_value_off` is the absolute
## offset of the first row's `value_q16`, which is what a content-refusal case has to
## damage: every other field of the row either changes the shape (refused earlier, by a
## different reason) or the ordering (also a shape refusal).
func _walk_scalar_block(bytes: PackedByteArray, block_off: int) -> Dictionary:
	var out := {"rows": 0, "end": block_off, "error": "", "first_handle": 0,
		"first_metric": -1, "first_value": 0, "first_value_off": -1,
		"foreign_handles": 0, "ascending": true, "nonzero": 0}
	if block_off < 0 or block_off + 4 > bytes.size():
		out["error"] = "count_unreadable"
		return out
	var count: int = int(bytes.decode_u32(block_off))
	out["rows"] = count
	var cursor: int = block_off + 4
	var previous_handle := -1
	var previous_metric := -1
	for index in range(count):
		if cursor + PKID_SCALAR_ROW_BYTES > bytes.size():
			out["error"] = "row_unreadable@%d" % index
			return out
		var handle: int = int(bytes.decode_u64(cursor))
		var metric: int = int(bytes.decode_s32(cursor + 8))
		var value_off: int = cursor + 12
		var value: int = int(bytes.decode_s64(value_off))
		if index == 0:
			out["first_handle"] = handle
			out["first_metric"] = metric
			out["first_value"] = value
			out["first_value_off"] = value_off
		elif handle != int(out["first_handle"]):
			out["foreign_handles"] = int(out["foreign_handles"]) + 1
		if handle < previous_handle or (handle == previous_handle
				and metric <= previous_metric):
			out["ascending"] = false
		if value != 0:
			out["nonzero"] = int(out["nonzero"]) + 1
		previous_handle = handle
		previous_metric = metric
		cursor += PKID_SCALAR_ROW_BYTES
	out["end"] = cursor
	return out


## Walks the applied-basis block from its start, one row at a time.
##
## Returns the offset just past the last row so the caller can prove the block's own
## declared length is the TRUTH about its contents rather than a number the reader never
## checks. `first_*` describe the first row, which is what the ABI assertions compare
## against the runtime's catalog.
func _walk_basis_block(bytes: PackedByteArray, block_off: int) -> Dictionary:
	var out := {"rows": 0, "end": block_off, "first_row_off": block_off + 4,
		"first_handle": 0, "first_program_key": "", "first_selector_kind": -1,
		"first_selector_id": "", "first_terms_digest": 0, "first_digest_off": -1,
		"error": ""}
	if block_off < 0 or block_off + 4 > bytes.size():
		out["error"] = "count_unreadable"
		return out
	var count: int = int(bytes.decode_u32(block_off))
	out["rows"] = count
	var cursor: int = block_off + 4
	for index in range(count):
		if cursor + 8 + 4 > bytes.size():
			out["error"] = "row_handle_unreadable@%d" % index
			return out
		var handle: int = int(bytes.decode_u64(cursor))
		cursor += 8
		var key_len: int = int(bytes.decode_u32(cursor))
		cursor += 4
		if key_len > 512 or cursor + key_len + 4 + 4 > bytes.size():
			out["error"] = "row_key_invalid@%d key_len=%d" % [index, key_len]
			return out
		var program_key := bytes.slice(cursor, cursor + key_len).get_string_from_utf8()
		cursor += key_len
		var selector_kind: int = int(bytes.decode_s32(cursor))
		cursor += 4
		var id_len: int = int(bytes.decode_u32(cursor))
		cursor += 4
		if id_len > 512 or cursor + id_len + 4 + 4 + 8 > bytes.size():
			out["error"] = "row_selector_id_invalid@%d len=%d" % [index, id_len]
			return out
		var selector_id := bytes.slice(cursor, cursor + id_len).get_string_from_utf8()
		cursor += id_len
		cursor += 4   # selector_param[0]
		cursor += 4   # selector_param[1]
		var digest_off: int = cursor
		var terms_digest: int = int(bytes.decode_u64(cursor))
		cursor += 8
		if index == 0:
			out["first_handle"] = handle
			out["first_program_key"] = program_key
			out["first_selector_kind"] = selector_kind
			out["first_selector_id"] = selector_id
			out["first_terms_digest"] = terms_digest
			out["first_digest_off"] = digest_off
	out["end"] = cursor
	return out


## The PKEF header, field by field, against `get_effect_report()`
## (`effect_runtime.cpp:6845-6877`). Returns nothing: unlike PKID the offsets are
## fixed, so the corruption cases can use the constants directly.
func _expect_pkef_abi(bytes: PackedByteArray, ext: Object, tag: String) -> void:
	_expect("%s: PKEF ABI: the payload reaches past the binding count (%d bytes)"
		% [tag, PKEF_OFF_BINDING_COUNT + 4],
		bytes.size() > PKEF_OFF_BINDING_COUNT + 4, "%d bytes" % bytes.size())
	if bytes.size() <= PKEF_OFF_BINDING_COUNT + 4:
		return
	var report: Dictionary = ext.get_effect_report()
	_expect("%s: PKEF ABI: u32 @ 0 is the PKEF magic 0x%08X" % [tag, PKEF_MAGIC],
		bytes.decode_u32(PKEF_OFF_MAGIC) == PKEF_MAGIC,
		"0x%08X" % bytes.decode_u32(PKEF_OFF_MAGIC))
	_expect("%s: PKEF ABI: i32 @ 4 is schema %d (the runtime reports %s)"
		% [tag, PKEF_SCHEMA, str(report.get("save_schema_version", "?"))],
		bytes.decode_s32(PKEF_OFF_SCHEMA) == PKEF_SCHEMA
			and bytes.decode_s32(PKEF_OFF_SCHEMA)
				== int(report.get("save_schema_version", -1)),
		str(bytes.decode_s32(PKEF_OFF_SCHEMA)))
	_expect("%s: PKEF ABI: i32 @ 8 is protocol %d" % [tag, PKEF_PROTOCOL],
		bytes.decode_s32(PKEF_OFF_PROTOCOL) == PKEF_PROTOCOL
			and bytes.decode_s32(PKEF_OFF_PROTOCOL)
				== int(report.get("protocol_version", -1)),
		str(bytes.decode_s32(PKEF_OFF_PROTOCOL)))
	_expect("%s: PKEF ABI: u64 @ 12 is the Effect catalog hash the runtime reports"
		% tag, bytes.decode_u64(PKEF_OFF_CATALOG)
			== int(report.get("catalog_hash", 0)),
		"payload=%s report=%s" % [str(bytes.decode_u64(PKEF_OFF_CATALOG)),
			str(report.get("catalog_hash", "?"))])
	_expect("%s: PKEF ABI: i64 @ 20 is the runtime's current day" % tag,
		bytes.decode_s64(PKEF_OFF_CURRENT_DAY)
			== int(report.get("current_day", -999)),
		"payload=%s report=%s" % [str(bytes.decode_s64(PKEF_OFF_CURRENT_DAY)),
			str(report.get("current_day", "?"))])
	_expect("%s: PKEF ABI: i64 @ 28 is the runtime's last completed day" % tag,
		bytes.decode_s64(PKEF_OFF_LAST_COMPLETED_DAY)
			== int(report.get("last_completed_day", -999)),
		"payload=%s report=%s" % [
			str(bytes.decode_s64(PKEF_OFF_LAST_COMPLETED_DAY)),
			str(report.get("last_completed_day", "?"))])
	_expect("%s: PKEF ABI: u32 @ %d is the instance storage slot count"
		% [tag, PKEF_OFF_INSTANCE_COUNT],
		bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT)
			== int(report.get("instance_storage_slots", -1)),
		"payload=%s report=%s" % [str(bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT)),
			str(report.get("instance_storage_slots", "?"))])
	# Everything past `instance_count` is variable-length: instance rows, then the
	# candidate table, then the transaction rows, then the binding rows. The three
	# counts at 80/84/88 are therefore only at FIXED offsets while the instance
	# table is EMPTY -- a corruption case may only address them by constant on such
	# a payload. The populated payload is checked through the report's own totals
	# instead, which the equip lead asserts.
	var empty_tables: bool = bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT) == 0
	if empty_tables:
		_expect("%s: PKEF ABI: i32 @ %d is the candidate cursor (0, no rebuild is "
			% [tag, PKEF_OFF_CANDIDATE_CURSOR] + "in flight)",
			bytes.decode_s32(PKEF_OFF_CANDIDATE_CURSOR) == 0,
			str(bytes.decode_s32(PKEF_OFF_CANDIDATE_CURSOR)))
		_expect("%s: PKEF ABI: u32 @ %d is the candidate count (0)"
			% [tag, PKEF_OFF_CANDIDATE_COUNT],
			bytes.decode_u32(PKEF_OFF_CANDIDATE_COUNT) == 0,
			str(bytes.decode_u32(PKEF_OFF_CANDIDATE_COUNT)))
		_expect("%s: PKEF ABI: u32 @ %d is the transaction count"
			% [tag, PKEF_OFF_TRANSACTION_COUNT],
			bytes.decode_u32(PKEF_OFF_TRANSACTION_COUNT)
				== int(report.get("transactions", -1)),
			"payload=%s report=%s" % [
				str(bytes.decode_u32(PKEF_OFF_TRANSACTION_COUNT)),
				str(report.get("transactions", "?"))])
		_expect("%s: PKEF ABI: u32 @ %d is the external binding count"
			% [tag, PKEF_OFF_BINDING_COUNT],
			bytes.decode_u32(PKEF_OFF_BINDING_COUNT)
				== int(report.get("external_bindings", -1)),
			"payload=%s report=%s" % [
				str(bytes.decode_u32(PKEF_OFF_BINDING_COUNT)),
				str(report.get("external_bindings", "?"))])
	print("[rob/%s] PKEF %d bytes, schema=%d protocol=%d instances=%d "
		% [tag, bytes.size(), bytes.decode_s32(PKEF_OFF_SCHEMA),
			bytes.decode_s32(PKEF_OFF_PROTOCOL),
			bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT)]
		+ "reported transactions=%d bindings=%d current_day=%d"
		% [int(report.get("transactions", -1)),
			int(report.get("external_bindings", -1)),
			bytes.decode_s64(PKEF_OFF_CURRENT_DAY)])


## `ideology_runtime.cpp:6423-6432` puts the ledger and the 16-entry history ring
## between the country's points and its bitsets. Asserting that the ledger day and
## the history head are where the writer put them pins the row's interior, not
## only its head.
func _expect_ideology_day_abi(bytes: PackedByteArray, ext: Object, tag: String) -> void:
	var layout: Dictionary = _pkid_layout(bytes)
	var row: int = int(layout["country_row_off"])
	# handle(8) points(8) era(4) rng(8) draw_sequence(8) free_draws(2)
	# points_revision(8) baseline_ready(1) history_count(1) history_head(1)
	# baseline_population(8) baseline_buildings(8) lifetime_points(8)
	# trade_paid_day(8) then the 7 ledger fields.
	var off_history_count: int = row + 8 + 8 + 4 + 8 + 8 + 2 + 8 + 1
	var off_baseline_ready: int = row + 8 + 8 + 4 + 8 + 8 + 2 + 8
	_expect("%s: PKID ABI: the country row's baseline_ready flag (@ %d) is 0 or 1"
		% [tag, off_baseline_ready],
		bytes.decode_u8(off_baseline_ready) <= 1,
		str(bytes.decode_u8(off_baseline_ready)))
	var history_count: int = int(bytes.decode_u8(off_history_count))
	_expect("%s: PKID ABI: the country row's history_count (@ %d) is a small ring "
		% [tag, off_history_count] + "cursor, not garbage", history_count <= 16,
		str(history_count))
	print("[rob/%s] PKID country row: era=%d history_count=%d baseline_ready=%d "
		% [tag, bytes.decode_s32(int(layout["unlocked_era_off"])), history_count,
			bytes.decode_u8(off_baseline_ready)]
		+ "rng_state=0x%016X" % bytes.decode_u64(int(layout["rng_state_off"])))


# =====================================================================
# refusal harness
# =====================================================================

## Attempts one PKID restore and asserts THREE things: refused, refused for the
## RIGHT LAYER, and atomic. `expected` is the reason code the C++ layer promises;
## an empty `expected` accepts any `ideology_save_*` code and is not used by any
## case today -- it exists so a future case can require only the family.
func _refuse_pkid(target: Object, tag: String, payload: PackedByteArray,
		expected: String) -> String:
	var before: PackedByteArray = target.capture_ideology_state()
	var before_business: Dictionary = target.get_ideology_business_state()
	var before_day: int = int(before_business.get("committed_day", -999))
	var result: Dictionary = target.restore_ideology_state(payload)
	var reason := String(result.get("reason", ""))
	var ok := bool(result.get("ok", false))
	var after: PackedByteArray = target.capture_ideology_state()
	_expect("%s: refused (never accepted with garbage)" % tag, not ok,
		"ok=true reason=%s" % reason)
	if expected.is_empty():
		_expect("%s: the reason is a PKID save-level code" % tag,
			reason.begins_with("ideology_save"), "observed=%s" % reason)
	else:
		_expect("%s: the refusal carries the layer's own reason `%s`"
			% [tag, expected], reason == expected, "observed=%s" % reason)
	_expect("%s: the runtime is left BYTE-IDENTICAL (nothing half-restored)" % tag,
		before == after, "%d vs %d bytes, first diff @%d" % [before.size(),
			after.size(), _first_diff(before, after)])
	_expect("%s: the committed day is unchanged" % tag,
		int(target.get_ideology_business_state().get("committed_day", -999))
			== before_day,
		"%d vs %d" % [int(target.get_ideology_business_state().get(
			"committed_day", -999)), before_day])
	print("  [CASE] %s -> reason=%s" % [tag, reason if not ok else "<ACCEPTED>"])
	return reason


## Same contract for PKEF, measured through `capture_effect_state()`.
func _refuse_pkef(target: Object, tag: String, payload: PackedByteArray,
		expected: String) -> String:
	var before: PackedByteArray = target.capture_effect_state()
	var before_day: int = int(target.get_effect_report().get("current_day", -999))
	var result: Dictionary = target.restore_effect_state(payload)
	var reason := String(result.get("reason", ""))
	var ok := bool(result.get("ok", false))
	var after: PackedByteArray = target.capture_effect_state()
	_expect("%s: refused (never accepted with garbage)" % tag, not ok,
		"ok=true reason=%s" % reason)
	if expected.is_empty():
		_expect("%s: the reason is a PKEF-level code" % tag,
			reason.begins_with("pkef") or reason.begins_with("effect_")
				or reason.begins_with("catalog_hash") or reason.begins_with("era_reward"),
			"observed=%s" % reason)
	else:
		_expect("%s: the refusal carries the layer's own reason `%s`"
			% [tag, expected], reason == expected, "observed=%s" % reason)
	_expect(("%s: the Effect runtime is left BYTE-IDENTICAL (PKEF parses all, "
		+ "then commits; nothing is applied before the end marker)") % tag,
		before == after, "%d vs %d bytes, first diff @%d" % [before.size(),
			after.size(), _first_diff(before, after)])
	_expect("%s: the Effect runtime's day is unchanged" % tag,
		int(target.get_effect_report().get("current_day", -999)) == before_day,
		"%d vs %d" % [int(target.get_effect_report().get("current_day", -999)),
			before_day])
	print("  [CASE] %s -> reason=%s" % [tag, reason if not ok else "<ACCEPTED>"])
	return reason


# =====================================================================
# depth: the sampled single-byte sweep
# =====================================================================

## Corrupts every `stride`-th byte of `payload` once and restores it.
##
## Returns the accepted offsets. It asserts the two properties the formats DO
## promise -- a diagnosable answer for every attempt, and a runtime that still
## takes the pristine payload afterwards -- and reports the accepted set, whose
## size is the honest measure of how much of each stream is outside every check.
func _sweep(target: Object, tag: String, payload: PackedByteArray,
		is_pkid: bool) -> PackedInt32Array:
	const STRIDE := 8
	var accepted := PackedInt32Array()
	var refused := 0
	var reasons := {}
	var scanned := 0
	for offset in range(0, payload.size(), STRIDE):
		var copy: PackedByteArray = payload.duplicate()
		copy.encode_u8(offset, copy.decode_u8(offset) ^ 0xFF)
		var result: Dictionary
		if is_pkid:
			result = target.restore_ideology_state(copy)
		else:
			result = target.restore_effect_state(copy)
		scanned += 1
		if bool(result.get("ok", false)):
			accepted.append(offset)
			continue
		refused += 1
		var reason := String(result.get("reason", ""))
		reasons[reason] = int(reasons.get(reason, 0)) + 1
	_expect("%s SWEEP: all %d sampled single-byte corruptions produce a "
		% [tag, scanned] + "diagnosable answer (a Dictionary with a String reason), "
		+ "and none crashes the process", scanned == refused + accepted.size()
		and scanned > 0, "scanned=%d refused=%d accepted=%d" % [scanned, refused,
			accepted.size()])
	# Self-heal: whatever the sweep left behind, the pristine payload must still
	# load. This is the "the runtime is not wedged" half of the robustness demand.
	var pristine: Dictionary
	if is_pkid:
		pristine = target.restore_ideology_state(payload)
	else:
		pristine = target.restore_effect_state(payload)
	_expect("%s SWEEP: the runtime still accepts the pristine payload after %d "
		% [tag, scanned] + "corruptions", bool(pristine.get("ok", false)),
		"reason=%s" % String(pristine.get("reason", "")))
	var reason_list := PackedStringArray()
	for key in reasons:
		reason_list.append("%s x%d" % [String(key), int(reasons[key])])
	reason_list.sort()
	print("[rob/%s SWEEP] %d of %d sampled corruptions refused, %d ACCEPTED; "
		% [tag, refused, scanned, accepted.size()]
		+ "accepted offsets=%s" % str(accepted))
	print("[rob/%s SWEEP] refusal layers: %s" % [tag, ", ".join(reason_list)])
	if not accepted.is_empty():
		_finding("%s accepts %d of %d sampled single-byte corruptions: the "
			% [tag, accepted.size(), scanned]
			+ "uncovered bytes are %s" % _offset_ranges(accepted, STRIDE))
	return accepted


## Collapses a sorted offset list into `a-b` ranges so a log line stays readable.
func _offset_ranges(offsets: PackedInt32Array, stride: int) -> String:
	if offsets.is_empty():
		return "(none)"
	var parts := PackedStringArray()
	var start := int(offsets[0])
	var last := start
	for i in range(1, offsets.size()):
		var value := int(offsets[i])
		if value == last + stride:
			last = value
			continue
		parts.append("%d-%d" % [start, last] if start != last else str(start))
		start = value
		last = value
	parts.append("%d-%d" % [start, last] if start != last else str(start))
	return ", ".join(parts) + " (every %dth byte sampled)" % stride


# =====================================================================
# capture
# =====================================================================


func _capture_pair(ext: Object, label: String) -> Dictionary:
	var pkef: PackedByteArray = ext.capture_effect_state()
	var pkid: PackedByteArray = ext.capture_ideology_state()
	_expect("%s: capture_ideology_state() returns a PackedByteArray" % label,
		pkid is PackedByteArray, str(typeof(pkid)))
	_expect("%s: capture_effect_state() returns a PackedByteArray" % label,
		pkef is PackedByteArray, str(typeof(pkef)))
	_expect("%s: the PKID payload is non-empty" % label, not pkid.is_empty(),
		str(pkid.size()))
	_expect("%s: the PKEF payload is non-empty" % label, not pkef.is_empty(),
		str(pkef.size()))
	if pkid.is_empty() or pkef.is_empty():
		return {}
	_expect("%s: the PKID payload starts with the ASCII magic `PKID`" % label,
		_ascii_magic(pkid) == "PKID", "%s (%d bytes)" % [_ascii_magic(pkid),
			pkid.size()])
	_expect("%s: the PKEF payload starts with the ASCII magic `PKEF`" % label,
		_ascii_magic(pkef) == "PKEF", "%s (%d bytes)" % [_ascii_magic(pkef),
			pkef.size()])
	print("[rob/%s] pkid=%d bytes (magic %s, schema %s) pkef=%d bytes (magic %s, "
		% [label, pkid.size(), _ascii_magic(pkid), str(pkid.decode_s32(
			PKID_OFF_SCHEMA)), pkef.size(), _ascii_magic(pkef)]
		+ "schema %s)" % str(pkef.decode_s32(PKEF_OFF_SCHEMA)))
	return {"pkid": pkid, "pkef": pkef}


# =====================================================================
# the equip lead (only where L26 needs a binding)
# =====================================================================

## Drives the card to ACTIVE and returns the pair captured there.
##
## The card is a derived cell card (kind 12), so its equip creates an EXTERNAL
## BINDING (`ideology_runtime.cpp:3596-3607`) but no one-shot Effect instance.
## The location and the binding are written BEFORE any ACK is collected, which is
## why this fixture needs neither `dispatch_effect_native_modifier` nor the
## poll/preflight/commit/ack cycle: the state L26 checks exists as soon as the
## transition starts. The transition itself may still be in flight; that is real
## business state and PKID carries it (`transition.active`, `:6453-6475`).
func _equip_until_active(world: Dictionary, dense: int) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	_submit(ext, _batch(2, 0, -1, 64 * Q16_ONE, 1), handle)   # GRANT points
	_submit(ext, _batch(1, 0, dense, 0, 2), handle)           # DISCOVER
	_run_one_ideology_day(ext, 0, "equip/day0-discover")
	_submit(ext, _batch(8, 0, dense, LEVEL2_UNDERSTANDING_Q16, 3), handle)
	_submit(ext, _batch(5, 0, dense, 0, 4), handle)           # EQUIP (due day 0)
	var active := 0
	for day in range(0, EQUIP_DAYS + 1):
		if day > 0:
			_advance_economy_day(ext, day)
		_run_one_ideology_day(ext, day, "equip/day%d" % day)
		var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
		active = _active_locations(snapshot)
		if active > 0:
			print("[rob/equip] the card became ACTIVE on day %d (locations=%s "
				% [day, str(snapshot.get("locations", "?"))]
				+ "levels=%s understanding=%s)" % [
					str(snapshot.get("levels", "?")),
					str(snapshot.get("understanding_q16", "?"))])
			break
	_expect("EQUIP: the card reaches a non-INACTIVE location slot (L26 needs an "
		+ "equipped row)", active > 0, "locations=%s"
		% str(ext.get_ideology_snapshot(handle).get("locations", "?")))
	var report: Dictionary = ext.get_effect_report()
	_expect("EQUIP: the equip registered an EXTERNAL BINDING in the Effect "
		+ "runtime (this is what PKID alone cannot prove on load)",
		int(report.get("external_bindings", 0)) >= 1,
		str(report.get("external_bindings", "?")))
	if active == 0:
		return {}
	return _capture_pair(ext, "ARMED")


func _batch(op: int, day: int, idea: int, value_q16: int,
		sequence: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([op]),
		"effective_days": PackedInt64Array([day]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([sequence]),
		"country_handles": PackedInt64Array([0]),
		"ideology_ids": PackedInt32Array([idea]),
		"values_q16": PackedInt64Array([value_q16]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	}


func _submit(ext: Object, batch: Dictionary, handle: int) -> void:
	var copy: Dictionary = batch.duplicate(true)
	copy["country_handles"] = PackedInt64Array([handle])
	var result: Dictionary = ext.submit_ideology_commands(copy)
	_expect("ideology batch (seq %d) is admitted" % int(batch["sequences"][0]),
		bool(result.get("ok", false)), str(result))


# =====================================================================
# catalogs + world (lifted from ideology_save_before_layer_test.gd)
# =====================================================================

func _compile_catalogs() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	if country_ir.is_empty() or effect_ir.is_empty() or mod_ir.is_empty() \
			or native_ideology.is_empty():
		_expect("all four native catalogs compile", false, "one of them is empty")
		return {}
	return {
		"country_ir": country_ir, "profile": profile, "effect_ir": effect_ir,
		"mod_ir": mod_ir, "native_ideology": native_ideology,
	}


## Declares `cell.settlement` as `cell.population >= 30`, which every cell of this
## fixture satisfies. The shipped predicate reads building data a bootstrapped
## economy does not have, so a card filtered on it legitimately matches NOTHING.
func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",   # dense id 9 -- never move this
		"op": 0,                       # TARGET_TAG_GTE
		"threshold_q16": 30 * Q16_ONE,
		"clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags


func _new_world(label: String) -> Dictionary:
	var country_ir: Dictionary = _catalogs["country_ir"]
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_ext_fill_environment(ext)
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(country_ir, _catalogs["profile"], CELLS, SEED)
			.get("ok", false)))
	_expect("%s: effects configure" % label,
		bool(ext.configure_effects(_catalogs["effect_ir"]).get("ok", false)))
	_expect("%s: modifiers configure" % label,
		bool(ext.configure_modifiers(_catalogs["mod_ir"], CELLS).get("ok", false)))
	_expect("%s: country configures" % label,
		bool(ext.configure_country(country_ir, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELLS, SEED).get("ok", false)))

	# A scattered 2/3 of the grid, non-contiguous on purpose.
	var owned_cells := PackedInt32Array()
	for c in range(CELLS):
		var x: int = c % WIDTH
		var y: int = c >> ROW_SHIFT
		if (x + 2 * y) % 3 != 0:
			owned_cells.append(c)
	_expect("%s: the fixture territory is a proper subset of the grid" % label,
		owned_cells.size() > 0 and owned_cells.size() < CELLS,
		"%d of %d" % [owned_cells.size(), CELLS])

	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.sv1"]),
		"country_names": PackedStringArray(["Save Point One"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, owned_cells.size()]),
		"territory_cells": owned_cells,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("%s: the country bootstraps" % label, bool(boot.get("ok", false)),
		str(boot))
	var ideo_cfg: Dictionary = ext.configure_ideologies(_catalogs["native_ideology"])
	_expect("%s: ideologies configure" % label, bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg)))

	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	_expect("%s: bootstrap_country registered exactly the intended territory"
		% label, owned == owned_cells.size(), "%d vs %d" % [owned,
			owned_cells.size()])

	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1,
		"resource_generation": 1})
	_expect("%s: the economy epoch opens" % label, bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var econ_catalog: Dictionary = _catalogs.get("economy_catalog", {})
	if econ_catalog.is_empty():
		econ_catalog = EconomyCatalogScript.compile_native_catalog()
		_catalogs["economy_catalog"] = econ_catalog
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys",
		PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var serf: int = sig_keys.find("serf|default")
	_expect("%s: the fixture resolves both bootstrap signatures" % label,
		farmer >= 0 and serf >= 0, "farmer=%d serf=%d" % [farmer, serf])
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	var ci := PackedInt32Array()
	var si := PackedInt32Array()
	var pp := PackedInt64Array()
	var ff := PackedInt64Array()
	for c in range(CELLS):
		for pair in [[farmer, 20], [serf, 20]]:
			ci.append(c)
			si.append(int(pair[0]))
			pp.append(int(pair[1]))
			ff.append(10000000)
	var eb: Dictionary = ext.bootstrap_economy({
		"cell_indices": ci, "signature_ids": si,
		"population": pp, "funds": ff,
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array(),
		"building_type_ids": PackedInt32Array(),
		"building_owner_signatures": PackedInt32Array(),
		"building_counts": PackedInt64Array(),
	})
	_expect("%s: the economy bootstraps" % label, bool(eb.get("ok", false)), str(eb))
	var slices := _advance_economy_day(ext, 0)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	# The epoch dictionary is ALIASED to the runtime cache; `duplicate(true)` it
	# before anyone holds it past the epoch that made it.
	var economy: Dictionary = ext.get_economy_report().duplicate(true)
	return {
		"label": label, "ext": ext, "handle": handle,
		"owned": owned_cells.size(), "owned_cells": owned_cells,
		"epoch_active": bool(economy.get("epoch_active", true)),
	}


func _ext_fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


func _u8_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


# =====================================================================
# advancing
# =====================================================================

func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var last := {}
	for _i in range(512):
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes" % [label, day], done, str(last))
	return done


func _advance_economy_day(ext: Object, day: int) -> int:
	for s in range(4096):
		var r: Dictionary = ext.run_economy_slice({"day_index": day, "tick_index": s})
		if bool(r.get("fatal", false)):
			_expect("economy day %d stays non-fatal" % day, false,
				str(r.get("fatal_reason", r)))
			return s
		if bool(r.get("done", false)):
			return s + 1
	_expect("economy day %d completes" % day, false, "4096 slices")
	return 0


# =====================================================================
# report
# =====================================================================

func _active_locations(snapshot: Dictionary) -> int:
	var locations: PackedInt32Array = snapshot.get("locations", PackedInt32Array())
	var count := 0
	for value in locations:
		if int(value) != 0:
			count += 1
	return count


func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


func _first_diff(a: PackedByteArray, b: PackedByteArray) -> int:
	var limit: int = mini(a.size(), b.size())
	for i in range(limit):
		if a[i] != b[i]:
			return i
	return -1 if a.size() == b.size() else limit


## Every check is printed, pass or fail: the evidence is the LIST of layers that
## were refused, and a log that only shows failures cannot tell a reader whether
## layer L8 ran at all.
func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s %s" % [label, detail])
	printerr("FAIL %s %s" % [label, detail])


## A defect the runtime exhibits, recorded WITHOUT failing the run: the point is
## that the acceptance is measured and named, not that this fixture can fix it.
## Sending a corrupt payload back into the runtime is what proves it.
func _finding(label: String, detail: String = "") -> void:
	_findings += 1
	print("  [FINDING] %s" % label)
	print("            %s" % detail)


func _finish() -> void:
	print("")
	print("=== ideology save payload robustness (18.2: corrupt / truncated / "
		+ "old-schema / ABI): %d checks, %d failures, %d finding(s) ==="
		% [_checks, _failures, _findings])
	quit(0 if _failures == 0 else 1)
